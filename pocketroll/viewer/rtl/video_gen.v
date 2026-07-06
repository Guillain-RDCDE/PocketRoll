// video_gen — raster generator for the on-board viewer. Walks an H/V counter over a
// frame, drives the openFPGA video interface (rgb / de / hs / vs), and paints the
// IMG_W×IMG_H photo (from the framebuffer, 2bpp) at (IMG_X,IMG_Y), 1:1; everything
// else is BORDER. The Pocket's own scaler enlarges the whole frame, so v1 draws the
// 128×112 image un-scaled and centred.
//
// Fully parameterised so the testbench can exercise it at a tiny scale; instantiate
// with the real numbers (HACT=160, VACT=144, IMG_W=128, IMG_H=112, FB_STRIDE=128) in
// core_top. The framebuffer read is asynchronous here (combinational); on a real BRAM
// (registered read) add one pipeline stage — noted in the README.
`default_nettype none
module video_gen #(
  parameter HACT=160, HFP=8,  HSW=32, HBP=40,
  parameter VACT=144, VFP=3,  VSW=8,  VBP=14,
  parameter IMG_X=16, IMG_Y=16, IMG_W=128, IMG_H=112, FB_STRIDE=128,
  parameter [23:0] PAL0=24'hE0F8D0, PAL1=24'h88C070, PAL2=24'h346856, PAL3=24'h081820,
  parameter [23:0] BORDER=24'h101810,
  parameter AW=15   // framebuffer address width
)(
  input  wire        clk,        // pixel clock
  input  wire        rst,
  output wire [AW-1:0] fb_addr,  // framebuffer read address (async read assumed)
  input  wire [1:0]  fb_data,
  output reg  [23:0] video_rgb,
  output reg         video_de,
  output reg         video_hs,   // active high
  output reg         video_vs,   // active high
  output wire        video_clk
);
  localparam HTOTAL = HACT+HFP+HSW+HBP;
  localparam VTOTAL = VACT+VFP+VSW+VBP;
  // enough bits for the counters
  localparam HW = (HTOTAL <= 256) ? 9 : (HTOTAL <= 1024 ? 11 : 13);
  localparam VW = (VTOTAL <= 256) ? 9 : (VTOTAL <= 1024 ? 11 : 13);

  reg [HW-1:0] hcnt;
  reg [VW-1:0] vcnt;

  assign video_clk = clk;

  // combinational decode of the *current* pixel (hcnt,vcnt)
  wire de_c  = (hcnt < HACT) && (vcnt < VACT);
  wire hs_c  = (hcnt >= HACT+HFP) && (hcnt < HACT+HFP+HSW);
  wire vs_c  = (vcnt >= VACT+VFP) && (vcnt < VACT+VFP+VSW);
  wire in_img = de_c && (hcnt >= IMG_X) && (hcnt < IMG_X+IMG_W)
                     && (vcnt >= IMG_Y) && (vcnt < IMG_Y+IMG_H);
  wire [15:0] ix = hcnt - IMG_X;
  wire [15:0] iy = vcnt - IMG_Y;
  assign fb_addr = iy*FB_STRIDE + ix;             // valid when in_img
  reg  [23:0] pix;
  always @(*) case (fb_data)
    2'd0: pix = PAL0; 2'd1: pix = PAL1; 2'd2: pix = PAL2; default: pix = PAL3;
  endcase
  wire [23:0] rgb_c = !de_c   ? 24'h000000 :      // blanking
                       in_img ? pix        :
                                BORDER;

  always @(posedge clk) begin
    if (rst) begin
      hcnt <= 0; vcnt <= 0;
      video_de <= 0; video_hs <= 0; video_vs <= 0; video_rgb <= 0;
    end else begin
      // register outputs together (all derived from the same hcnt/vcnt) → aligned
      video_de  <= de_c;
      video_hs  <= hs_c;
      video_vs  <= vs_c;
      video_rgb <= rgb_c;
      // advance raster
      if (hcnt == HTOTAL-1) begin
        hcnt <= 0;
        vcnt <= (vcnt == VTOTAL-1) ? 0 : vcnt + 1'b1;
      end else hcnt <= hcnt + 1'b1;
    end
  end
endmodule
`default_nettype wire
