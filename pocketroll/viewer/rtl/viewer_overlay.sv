// viewer_overlay — grafts the photo viewer onto budude2's video pipeline WITHOUT adding a
// 128 KB buffer: it decodes directly from the GB core's EXISTING cart RAM (`cram`, which
// already holds the camera's photos), read through a port exposed by cart_top. It only
// ADDS a 14336×2 framebuffer (3.5 KB) + the tile decoder + D-pad nav + the overlay pixel.
//
// The cram byte read is registered (1-cycle), matching gbcam_photo_decode. Photo at slot i
// lives at 0x2000 + i*0x1000 (base 0, since cram IS the 128 KB cart RAM). Image is centred
// (128×112 in 160×144). STATUS: assembled for a Quartus build; the standalone logic
// elaborates and reuses the simulation-verified decoder, but the integration is not
// hardware-tested. Fixes the M10K overflow from the first build (no on-chip file buffer).
`default_nettype none
module viewer_overlay #(
  parameter IMG_X = 16, IMG_Y = 16,       // centre 128×112 in 160×144
  parameter [23:0] PAL0=24'hE0F8D0, PAL1=24'h88C070, PAL2=24'h346856, PAL3=24'h081820
)(
  input  wire        clk_sys,
  input  wire        clk_vid,
  input  wire        rst,
  input  wire        refresh,           // pulse: (re)decode the current slot (e.g. on enable)
  // D-pad (clk_sys, one-cycle pulses)
  input  wire        key_next,
  input  wire        key_prev,
  // registered byte read into the GB core's cart RAM (cram), 1-cycle latency
  output wire [16:0] cram_addr,
  input  wire [7:0]  cram_data,
  // pixel position from budude2's video module (clk_vid == clk_ram here)
  input  wire [8:0]  h_cnt,
  input  wire [8:0]  v_cnt,
  output wire        ov_active,
  output reg  [23:0] ov_rgb
);
  // ── current slot + navigation ─────────────────────────────────────────────────
  reg  [4:0] cur_slot;
  reg        redecode;
  always @(posedge clk_sys) begin
    redecode <= 1'b0;
    if (rst) cur_slot <= 5'd0;
    else begin
      if (refresh)       begin redecode <= 1'b1; end
      else if (key_next) begin cur_slot <= (cur_slot==5'd29)? 5'd0 : cur_slot+1'b1; redecode <= 1'b1; end
      else if (key_prev) begin cur_slot <= (cur_slot==5'd0)? 5'd29 : cur_slot-1'b1; redecode <= 1'b1; end
    end
  end

  // ── decoder → framebuffer (reads cram) ────────────────────────────────────────
  wire [16:0] dec_addr;
  assign cram_addr = dec_addr;
  wire dec_we; wire [13:0] dec_waddr; wire [1:0] dec_wdata; wire dec_busy, dec_done;
  gbcam_photo_decode #(.AW(17)) u_dec(
    .clk(clk_sys),.rst(rst),.start(redecode & ~dec_busy),.base(17'd0),.slot(cur_slot),
    .mem_addr(dec_addr),.mem_data(cram_data),
    .fb_we(dec_we),.fb_addr(dec_waddr),.fb_data(dec_wdata),.busy(dec_busy),.done(dec_done));

  // ── framebuffer: dual-clock (decode writes on clk_sys, pixel reads on clk_vid) ─
  reg [1:0] fbmem [0:14335];
  always @(posedge clk_sys) if (dec_we) fbmem[dec_waddr] <= dec_wdata;

  wire in_win = (h_cnt>=IMG_X) && (h_cnt<IMG_X+128) && (v_cnt>=IMG_Y) && (v_cnt<IMG_Y+112);
  wire [13:0] praddr = ((v_cnt-IMG_Y) <<7) + (h_cnt-IMG_X);
  reg [1:0] fb_rd; reg in_win_d;
  always @(posedge clk_vid) begin fb_rd <= fbmem[praddr]; in_win_d <= in_win; end
  assign ov_active = in_win_d;
  always @(*) case (fb_rd) 2'd0:ov_rgb=PAL0; 2'd1:ov_rgb=PAL1; 2'd2:ov_rgb=PAL2; default:ov_rgb=PAL3; endcase
endmodule
`default_nettype wire
