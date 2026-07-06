`timescale 1ns/1ps
`default_nettype none
// Exercise video_gen at a tiny scale and compare every pixel (de/hs/vs/rgb) against
// an independent reference raster, over two full frames. Also checks the active-pixel
// count == HACT*VACT per frame.
module tb_video_gen;
  localparam HACT=16, HFP=2, HSW=3, HBP=2, HTOTAL=HACT+HFP+HSW+HBP;   // 23
  localparam VACT=12, VFP=1, VSW=2, VBP=1, VTOTAL=VACT+VFP+VSW+VBP;   // 16
  localparam IMG_X=2, IMG_Y=1, IMG_W=8, IMG_H=8, STRIDE=8;
  localparam [23:0] P0=24'h010101, P1=24'h020202, P2=24'h030303, P3=24'h040404, BRD=24'h111111;

  reg clk=0; always #5 clk=~clk;
  reg rst=1;

  reg  [1:0] fb [0:63];
  wire [5:0] fbaddr;
  wire [1:0] fbdata = fb[fbaddr];

  wire [23:0] rgb; wire de, hs, vs;
  video_gen #(.HACT(HACT),.HFP(HFP),.HSW(HSW),.HBP(HBP),.VACT(VACT),.VFP(VFP),.VSW(VSW),.VBP(VBP),
              .IMG_X(IMG_X),.IMG_Y(IMG_Y),.IMG_W(IMG_W),.IMG_H(IMG_H),.FB_STRIDE(STRIDE),
              .PAL0(P0),.PAL1(P1),.PAL2(P2),.PAL3(P3),.BORDER(BRD),.AW(6)) dut(
    .clk(clk),.rst(rst),.fb_addr(fbaddr),.fb_data(fbdata),
    .video_rgb(rgb),.video_de(de),.video_hs(hs),.video_vs(vs),.video_clk());

  // reference raster (mirrors the DUT counters)
  reg [8:0] h=0, v=0;
  function [23:0] palof(input [1:0] p); case(p) 2'd0:palof=P0; 2'd1:palof=P1; 2'd2:palof=P2; default:palof=P3; endcase endfunction
  wire de_e = (h<HACT)&&(v<VACT);
  wire hs_e = (h>=HACT+HFP)&&(h<HACT+HFP+HSW);
  wire vs_e = (v>=VACT+VFP)&&(v<VACT+VFP+VSW);
  wire inimg = de_e && (h>=IMG_X)&&(h<IMG_X+IMG_W)&&(v>=IMG_Y)&&(v<IMG_Y+IMG_H);
  wire [23:0] rgb_e = !de_e ? 24'h0 : inimg ? palof(fb[(v-IMG_Y)*STRIDE + (h-IMG_X)]) : BRD;
  reg de_d, hs_d, vs_d; reg [23:0] rgb_d;

  integer i, bad, checks, de_count, frames;
  reg comparing;

  always @(posedge clk) begin
    // pipeline the reference by 1 to align with the DUT's registered outputs
    de_d<=de_e; hs_d<=hs_e; vs_d<=vs_e; rgb_d<=rgb_e;
    if (!rst) begin
      if (h==HTOTAL-1) begin h<=0; v<=(v==VTOTAL-1)?0:v+1'b1; end else h<=h+1'b1;
    end
    if (comparing) begin
      checks = checks + 1;
      if (de!==de_d || hs!==hs_d || vs!==vs_d || rgb!==rgb_d) begin
        bad = bad + 1;
        if (bad<=6) $display("  mismatch: de %b/%b hs %b/%b vs %b/%b rgb %06h/%06h", de,de_d,hs,hs_d,vs,vs_d,rgb,rgb_d);
      end
      if (de) de_count = de_count + 1;
    end
  end

  initial begin
    for (i=0;i<64;i=i+1) fb[i] = i[1:0];   // pattern uses all 4 shades
    bad=0; checks=0; de_count=0; comparing=0;
    @(negedge clk); rst<=0;
    @(negedge clk); @(negedge clk); comparing<=1;   // let the 1-cycle pipeline settle
    // run two full frames
    repeat (2*HTOTAL*VTOTAL) @(negedge clk);
    comparing<=0;
    $display("video_gen: %0d pixels checked, %0d mismatches, active(de) counted=%0d (expect %0d = 2 frames)",
             checks, bad, de_count, 2*HACT*VACT);
    if (bad==0 && de_count==2*HACT*VACT && checks>0) $display("*** VIDEO_GEN PASS ***");
    else $display("*** VIDEO_GEN FAIL ***");
    $finish;
  end
  initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
