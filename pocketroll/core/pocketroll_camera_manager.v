// =============================================================================
// pocketroll_camera_manager.v
// -----------------------------------------------------------------------------
// The orchestrator. Watches the core-served cartridge RAM for a freshly saved
// photo, then runs: EXPORT the photo to SD  ->  RECYCLE its slot. Repeat. That
// loop is what turns 30 slots into an infinite roll.
//
//   detect new photo (directory 0x11B2 gets a new entry)
//        -> pocketroll_export   (write photo data to the SD slot file)
//        -> pocketroll_recycle  (free the slot: 0xFF + checksum + echo)
//        -> advance album file offset
//        -> wait for the next photo
//
// ⚠️ SCAFFOLD / INTEGRATION SKETCH. Authored from the validated design; NOT yet
// built/simulated. Two things the integrator must finish inside the budude2 fork
// (see core/INTEGRATION.md):
//   (A) RAM ROUTING — make cart-RAM accesses (0xA000-0xBFFF, when NOT in camera
//       register mode) hit an internal byte RAM instead of the cartridge pins,
//       while ROM and camera registers stay on the physical cartridge. The
//       camera sensor passthrough is already confirmed working.
//   (B) CLOCK DOMAINS — recycle runs in the cart-RAM clock; export runs in the
//       APF clock (clk_74a). The single-clock view below is for clarity; wrap
//       the cross-domain `start`/`done` strobes in proper CDC handshakes.
// =============================================================================

module pocketroll_camera_manager #(
    parameter [31:0] RAM_BRIDGE_BASE = 32'h0000_0000, // bridge addr of internal cart RAM, byte 0
    parameter [16:0] PHOTO_DATA_OFF  = 17'h02000,     // first photo in cart RAM
    parameter [16:0] SLOT_SIZE       = 17'h01000,     // one photo slot
    parameter [31:0] PHOTO_BYTES     = 32'h0000_1000  // bytes exported per photo
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,        // master on/off (e.g. only the GB Camera cart)

    // --- (A) snoop of writes into the internal cart RAM directory region ------
    // Wire these to the internal RAM write port in the fork.
    input  wire        dir_wr,        // a write happened to cart RAM
    input  wire [16:0] dir_wr_addr,
    input  wire [7:0]  dir_wr_data,

    // --- recycle sub-module: cart-RAM master port (shared, arbitrated) --------
    output wire [16:0] rc_ram_addr,
    output wire        rc_ram_rd,
    input  wire [7:0]  rc_ram_rd_data,
    output wire        rc_ram_wr,
    output wire [7:0]  rc_ram_wr_data,

    // --- export sub-module: APF target data-slot interface --------------------
    output wire        target_dataslot_write,
    output wire [15:0] target_dataslot_id,
    output wire [31:0] target_dataslot_slotoffset,
    output wire [31:0] target_dataslot_bridgeaddr,
    output wire [31:0] target_dataslot_length,
    input  wire        target_dataslot_ack,
    input  wire        target_dataslot_done,
    input  wire [2:0]  target_dataslot_err,

    output reg  [15:0] photos_exported   // counter, handy for a HUD/debug
);

    // -------------------------------------------------------------------------
    // (1) New-photo detection.
    // The camera fills a slot, then writes the directory at 0x11B2..0x11CF: an
    // entry flips from 0xFF to a real slot number (0x00..0x1D). We treat that as
    // "a photo just landed in that slot". `gallery_pos` is the directory index;
    // `slot_num` is the byte value (the physical slot holding the image).
    // (A fuller version would also confirm the checksum settled.)
    // -------------------------------------------------------------------------
    localparam [16:0] VEC_START = 17'h011B2;
    localparam [16:0] VEC_END   = 17'h011CF;

    reg        photo_pending;
    reg [4:0]  gallery_pos;   // 0..29
    reg [7:0]  slot_num;      // 0x00..0x1D

    wire in_directory = (dir_wr_addr >= VEC_START) && (dir_wr_addr <= VEC_END);
    wire is_real_slot = (dir_wr_data != 8'hFF);

    // -------------------------------------------------------------------------
    // (2) The sequencer.
    // -------------------------------------------------------------------------
    localparam [2:0]
        M_IDLE    = 3'd0,
        M_EXPORT  = 3'd1,
        M_EXP_WAIT= 3'd2,
        M_RECYCLE = 3'd3,
        M_REC_WAIT= 3'd4;

    reg [2:0]  mstate;
    reg [31:0] album_offset;   // advances by PHOTO_BYTES each export (album mode)

    reg        exp_start, rc_start;
    wire       exp_busy, exp_done, exp_err;
    wire       rc_busy, rc_done;

    // source address of the photo currently being handled
    wire [31:0] photo_src_addr =
        RAM_BRIDGE_BASE + PHOTO_DATA_OFF + (slot_num * SLOT_SIZE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstate          <= M_IDLE;
            photo_pending   <= 1'b0;
            album_offset    <= 32'd0;
            photos_exported <= 16'd0;
            exp_start       <= 1'b0;
            rc_start        <= 1'b0;
        end else begin
            exp_start <= 1'b0;
            rc_start  <= 1'b0;

            // latch a new photo (only while idle, to keep it simple)
            if (enable && dir_wr && in_directory && is_real_slot && mstate == M_IDLE) begin
                photo_pending <= 1'b1;
                gallery_pos   <= dir_wr_addr - VEC_START; // index within 0x11B2.. (0..29)
                slot_num      <= dir_wr_data;
            end

            case (mstate)
            M_IDLE: begin
                if (photo_pending) begin
                    exp_start <= 1'b1;          // -> export this photo
                    mstate    <= M_EXPORT;
                end
            end

            M_EXPORT:   mstate <= M_EXP_WAIT;   // start consumed
            M_EXP_WAIT: begin
                if (exp_done) begin
                    if (!exp_err) begin
                        photos_exported <= photos_exported + 1'b1;
                        album_offset    <= album_offset + PHOTO_BYTES;
                    end
                    rc_start <= 1'b1;           // -> recycle the slot (even on err? choose policy)
                    mstate   <= M_RECYCLE;
                end
            end

            M_RECYCLE:   mstate <= M_REC_WAIT;
            M_REC_WAIT: begin
                if (rc_done) begin
                    photo_pending <= 1'b0;
                    mstate        <= M_IDLE;    // ready for the next shot
                end
            end

            default: mstate <= M_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // (3) Sub-modules.
    // -------------------------------------------------------------------------
    pocketroll_export #(
        .PHOTO_SLOT_ID (16'h0030),
        .PHOTO_BYTES   (PHOTO_BYTES)
    ) u_export (
        .clk(clk), .rst_n(rst_n),
        .start(exp_start), .src_addr(photo_src_addr), .file_offset(album_offset),
        .busy(exp_busy), .done(exp_done), .err(exp_err),
        .target_dataslot_write(target_dataslot_write),
        .target_dataslot_id(target_dataslot_id),
        .target_dataslot_slotoffset(target_dataslot_slotoffset),
        .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
        .target_dataslot_length(target_dataslot_length),
        .target_dataslot_ack(target_dataslot_ack),
        .target_dataslot_done(target_dataslot_done),
        .target_dataslot_err(target_dataslot_err)
    );

    pocketroll_recycle u_recycle (
        .clk(clk), .rst_n(rst_n),
        .start(rc_start), .gallery_pos(gallery_pos),
        .busy(rc_busy), .done(rc_done),
        .ram_addr(rc_ram_addr), .ram_rd(rc_ram_rd), .ram_rd_data(rc_ram_rd_data),
        .ram_wr(rc_ram_wr), .ram_wr_data(rc_ram_wr_data)
    );

endmodule
