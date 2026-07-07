// viewer_overlay — grafts the photo viewer onto budude2's video pipeline. It reuses
// core_top's clocks, video timing (h_cnt/v_cnt/ce_pix on clk_vid), the APF dataslot
// download (ioctl_*), and the D-pad; it only ADDS: a 128 KB file BRAM, the tile
// decoder, a framebuffer, D-pad navigation, and a pixel to overlay on the LCD output.
//
// v1 scope: a 128 KB .sav (cart RAM, base 0 — no Magic scan needed). The image is
// centred (128×112 inside the GB's 160×144). Empty slots decode to the lightest shade.
// .sta support (Magic scan via gbcam_sta_locate) + skipping empty slots via the summary
// vector are the next iterations. STATUS: assembled for the FIRST Quartus build — the
// standalone logic elaborates and reuses only simulation-verified submodules, but the
// full integration is not hardware-tested yet.
`default_nettype none
module viewer_overlay #(
  parameter WORDS = 65536,     // 128 KB as 16-bit words
  parameter IMG_X = 16, IMG_Y = 16,       // centre 128×112 in 160×144
  parameter [23:0] PAL0=24'hE0F8D0, PAL1=24'h88C070, PAL2=24'h346856, PAL3=24'h081820
)(
  input  wire        clk_sys,
  input  wire        clk_vid,
  input  wire        rst,
  // APF dataslot download (from core_top's ioctl_*), gated to our slot:
  input  wire        viewer_download,   // high while our savestate slot is loading
  input  wire        ioctl_wr,
  input  wire [24:0] ioctl_addr,        // byte address
  input  wire [15:0] ioctl_dout,        // 16-bit word
  input  wire        load_complete,     // pulse: dataslot_allcomplete
  // D-pad (clk_sys, one-cycle pulses)
  input  wire        key_next,
  input  wire        key_prev,
  // pixel position from budude2's video module (clk_vid)
  input  wire [8:0]  h_cnt,
  input  wire [8:0]  v_cnt,
  output wire        ov_active,         // this pixel is inside the photo
  output reg  [23:0] ov_rgb
);
  // ── file BRAM (128 KB), loaded over ioctl ─────────────────────────────────────
  reg [15:0] filemem [0:WORDS-1];
  always @(posedge clk_sys)
    if (viewer_download && ioctl_wr) filemem[ioctl_addr[16:1]] <= ioctl_dout;

  // registered byte read for the decoder (1-cycle latency, like real BRAM)
  wire [19:0] dec_addr;
  reg  [15:0] file_word; reg file_bsel;
  always @(posedge clk_sys) begin file_word <= filemem[dec_addr[16:1]]; file_bsel <= dec_addr[0]; end
  wire [7:0]  dec_data = file_bsel ? file_word[15:8] : file_word[7:0];

  // ── current slot + navigation ─────────────────────────────────────────────────
  reg  [4:0] cur_slot;
  reg        redecode;                 // 1-cycle request to (re)decode cur_slot
  always @(posedge clk_sys) begin
    redecode <= 1'b0;
    if (rst) begin cur_slot <= 5'd0; end
    else begin
      if (load_complete) begin cur_slot <= 5'd0; redecode <= 1'b1; end
      else if (key_next) begin cur_slot <= (cur_slot==5'd29)? 5'd0 : cur_slot+1'b1; redecode <= 1'b1; end
      else if (key_prev) begin cur_slot <= (cur_slot==5'd0)? 5'd29 : cur_slot-1'b1; redecode <= 1'b1; end
    end
  end

  // ── decoder → framebuffer ─────────────────────────────────────────────────────
  wire dec_we; wire [13:0] dec_waddr; wire [1:0] dec_wdata; wire dec_busy, dec_done;
  gbcam_photo_decode #(.AW(20)) u_dec(
    .clk(clk_sys),.rst(rst),.start(redecode & ~dec_busy),.base(20'd0),.slot(cur_slot),
    .mem_addr(dec_addr),.mem_data(dec_data),
    .fb_we(dec_we),.fb_addr(dec_waddr),.fb_data(dec_wdata),.busy(dec_busy),.done(dec_done));

  // ── framebuffer: dual-clock (decode writes on clk_sys, pixel reads on clk_vid) ─
  reg [1:0] fbmem [0:14335];
  always @(posedge clk_sys) if (dec_we) fbmem[dec_waddr] <= dec_wdata;

  wire in_win = (h_cnt>=IMG_X) && (h_cnt<IMG_X+128) && (v_cnt>=IMG_Y) && (v_cnt<IMG_Y+112);
  wire [13:0] praddr = ((v_cnt-IMG_Y) <<7) + (h_cnt-IMG_X);   // *128 + x
  reg [1:0] fb_rd; reg in_win_d;
  always @(posedge clk_vid) begin fb_rd <= fbmem[praddr]; in_win_d <= in_win; end
  assign ov_active = in_win_d;
  always @(*) case (fb_rd) 2'd0:ov_rgb=PAL0; 2'd1:ov_rgb=PAL1; 2'd2:ov_rgb=PAL2; default:ov_rgb=PAL3; endcase
endmodule
`default_nettype wire
