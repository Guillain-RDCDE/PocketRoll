// =============================================================================
// pocketroll_recycle.v
// -----------------------------------------------------------------------------
// Frees one Game Boy Camera photo slot, in place, inside the cartridge SRAM
// served by the core (see docs/05-export-recycling-design.md).
//
// This is the Verilog port of `tools/gbcam-sav.js free` — the recipe validated
// byte-for-byte against the real camera (docs/02-slot-recycling.md):
//   1. set the directory entry 0x11B2+pos to 0xFF
//   2. recompute the directory checksum (sum seed 0x2F, xor seed 0x15,
//      over 0x11B2..0x11CF) into 0x11D5 / 0x11D6
//   3. mirror 0x11B2..0x11D6 (37 bytes) into the echo at 0x11D7
//
// ⚠️ SCAFFOLD. Authored from the validated design; NOT yet built/simulated.
// Intended to be integrated into a fork of budude2/openfpga-GBC and driven by
// pocketroll_camera_manager.v. Arbitration of the shared cartridge RAM (against
// the Game Boy CPU) is the integrator's responsibility — drive `start` only
// when the CPU is not touching cart RAM (e.g. during VBlank / when halted).
//
// RAM port: byte-wide, single port, synchronous, 1-cycle read latency
// (assert ram_addr + ram_rd on cycle N, ram_rd_data valid on cycle N+1).
// =============================================================================

module pocketroll_recycle #(
    parameter [16:0] VEC_START  = 17'h011B2,  // directory / state vector
    parameter integer VEC_LEN   = 30,         // 30 entries
    parameter [16:0] CK_SUM     = 17'h011D5,  // checksum: 8-bit sum
    parameter [16:0] CK_XOR     = 17'h011D6,  // checksum: 8-bit xor
    parameter [16:0] ECHO_START = 17'h011D7,  // echo (mirror of 0x11B2..0x11D6)
    parameter integer BLOCK_LEN = 37,         // 0x11B2..0x11D6 inclusive
    parameter [7:0]  SUM_SEED   = 8'h2F,
    parameter [7:0]  XOR_SEED   = 8'h15
) (
    input  wire        clk,
    input  wire        rst_n,

    // command interface
    input  wire        start,        // 1-cycle pulse to begin
    input  wire [4:0]  gallery_pos,  // 0..29: directory entry to free
    output reg         busy,
    output reg         done,         // 1-cycle pulse on completion

    // cartridge-RAM master port (byte-wide, 1-cycle read latency)
    output reg  [16:0] ram_addr,
    output reg         ram_rd,
    input  wire [7:0]  ram_rd_data,
    output reg         ram_wr,
    output reg  [7:0]  ram_wr_data
);

    localparam [3:0]
        S_IDLE     = 4'd0,
        S_FREE     = 4'd1,   // write 0xFF into the directory entry
        S_SUM_ADDR = 4'd2,   // issue read of directory byte
        S_SUM_ACC  = 4'd3,   // accumulate sum/xor
        S_WR_SUM   = 4'd4,   // write checksum sum byte
        S_WR_XOR   = 4'd5,   // write checksum xor byte
        S_ECHO_RD  = 4'd6,   // issue read for echo copy
        S_ECHO_WR  = 4'd7,   // write echoed byte
        S_DONE     = 4'd8;

    reg [3:0]  state;
    reg [5:0]  idx;          // 0..BLOCK_LEN-1 (=36) for the echo → needs 6 bits, not 5
    reg [7:0]  sum, xorv;
    reg [4:0]  pos;          // latched gallery position
    reg [7:0]  echo_byte;    // byte captured during echo read

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            ram_rd   <= 1'b0;
            ram_wr   <= 1'b0;
        end else begin
            // defaults (single-cycle strobes)
            ram_rd <= 1'b0;
            ram_wr <= 1'b0;
            done   <= 1'b0;

            case (state)
            // -----------------------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    pos  <= gallery_pos;
                    state <= S_FREE;
                end
            end

            // 1. directory entry -> 0xFF
            S_FREE: begin
                ram_addr    <= VEC_START + pos;
                ram_wr_data <= 8'hFF;
                ram_wr      <= 1'b1;
                // prepare checksum pass
                sum  <= SUM_SEED;
                xorv <= XOR_SEED;
                idx  <= 5'd0;
                state <= S_SUM_ADDR;
            end

            // 2a. issue read of directory byte idx
            S_SUM_ADDR: begin
                ram_addr <= VEC_START + idx;
                ram_rd   <= 1'b1;
                state    <= S_SUM_ACC;
            end

            // 2b. capture byte (1-cycle latency), accumulate, loop or finish
            S_SUM_ACC: begin
                sum  <= sum  + ram_rd_data;     // mod 256 by 8-bit wrap
                xorv <= xorv ^ ram_rd_data;
                if (idx == VEC_LEN - 1) begin
                    state <= S_WR_SUM;
                end else begin
                    idx   <= idx + 1'b1;
                    state <= S_SUM_ADDR;
                end
            end

            // 2c. write checksum bytes
            S_WR_SUM: begin
                ram_addr    <= CK_SUM;
                ram_wr_data <= sum;
                ram_wr      <= 1'b1;
                state       <= S_WR_XOR;
            end
            S_WR_XOR: begin
                ram_addr    <= CK_XOR;
                ram_wr_data <= xorv;
                ram_wr      <= 1'b1;
                idx         <= 5'd0;
                state       <= S_ECHO_RD;
            end

            // 3. mirror 0x11B2..0x11D6 -> echo at 0x11D7
            S_ECHO_RD: begin
                ram_addr <= VEC_START + idx;
                ram_rd   <= 1'b1;
                state    <= S_ECHO_WR;
            end
            S_ECHO_WR: begin
                echo_byte   <= ram_rd_data;             // (captured)
                ram_addr    <= ECHO_START + idx;
                ram_wr_data <= ram_rd_data;
                ram_wr      <= 1'b1;
                if (idx == BLOCK_LEN - 1) begin
                    state <= S_DONE;
                end else begin
                    idx   <= idx + 1'b1;
                    state <= S_ECHO_RD;
                end
            end

            // -----------------------------------------------------------------
            S_DONE: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
