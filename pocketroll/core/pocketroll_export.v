// =============================================================================
// pocketroll_export.v
// -----------------------------------------------------------------------------
// Writes one finished photo (a region of the core-served cartridge RAM) to a
// file on the SD card, using APF Target data-slot commands.
//
// Confirmed feasible by the official core-example-kbmouse-targetdata, whose
// write sequence we mirror (see docs/05-export-recycling-design.md):
//     target_dataslot_id         <= slot id
//     target_dataslot_slotoffset <= file offset   (advance it => append => album)
//     target_dataslot_bridgeaddr <= source addr in core/bridge memory
//     target_dataslot_length     <= byte count
//     target_dataslot_write      <= 1   (pulse, then wait for ack -> done)
//
// MODE_ALBUM (default): append each photo into one growing slot file; the host
//   side (MugDump) splits it back into individual pictures.
// MODE_PERPHOTO (TODO): issue `0192 open new file into data slot` first to give
//   each photo its own filename (IMG_0001…). The param/response struct mapping
//   is the only remaining nicety — left as a hook below.
//
// ⚠️ SCAFFOLD. Authored from the validated design; NOT yet built/simulated.
// The `target_dataslot_*` ports connect to core_bridge_cmd (APF) in the budude2
// fork. Runs in the APF clock domain (clk_74a) like the example core.
// =============================================================================

module pocketroll_export #(
    parameter [15:0] PHOTO_SLOT_ID = 16'h0030,   // data slot for the exported album/photo
    parameter [31:0] PHOTO_BYTES   = 32'h0000_1000 // one slot = 0x1000 (image+thumb+meta);
                                                   // use 0x0E00 to export image only
) (
    input  wire        clk,            // APF clock (clk_74a)
    input  wire        rst_n,

    // command
    input  wire        start,          // pulse: export the photo at src_addr
    input  wire [31:0] src_addr,       // bridge/core address of the photo data
    input  wire [31:0] file_offset,    // where to write inside the slot file (album append)
    output reg         busy,
    output reg         done,
    output reg         err,

    // APF target data-slot interface (-> core_bridge_cmd)
    output reg         target_dataslot_write,
    output reg  [15:0] target_dataslot_id,
    output reg  [31:0] target_dataslot_slotoffset,
    output reg  [31:0] target_dataslot_bridgeaddr,
    output reg  [31:0] target_dataslot_length,
    input  wire        target_dataslot_ack,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err
);

    localparam [2:0]
        S_IDLE  = 3'd0,
        S_SETUP = 3'd1,   // load registers, raise write
        S_ACK   = 3'd2,   // wait for APF to accept the command
        S_WAIT  = 3'd3,   // wait for completion
        S_DONE  = 3'd4;

    reg [2:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                 <= S_IDLE;
            busy                  <= 1'b0;
            done                  <= 1'b0;
            err                   <= 1'b0;
            target_dataslot_write <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    busy  <= 1'b1;
                    err   <= 1'b0;
                    state <= S_SETUP;
                end
            end

            // MODE_ALBUM: write PHOTO_BYTES from src_addr to the slot file at
            // file_offset. (MODE_PERPHOTO would issue 0192 openfile here first.)
            S_SETUP: begin
                target_dataslot_id         <= PHOTO_SLOT_ID;
                target_dataslot_bridgeaddr <= src_addr;
                target_dataslot_slotoffset <= file_offset;
                target_dataslot_length     <= PHOTO_BYTES;
                target_dataslot_write      <= 1'b1;       // pulse
                state                      <= S_ACK;
            end

            S_ACK: begin
                if (target_dataslot_ack) begin
                    target_dataslot_write <= 1'b0;        // de-assert after ack
                    state                 <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (target_dataslot_done) begin
                    err   <= (target_dataslot_err != 3'd0);
                    state <= S_DONE;
                end
            end

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
