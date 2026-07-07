`timescale 1ns/1ps
`default_nettype none
module tb_photo_decode;
  localparam AW = 20;
  reg clk = 0; always #5 clk = ~clk;

  reg  [7:0] mem [0:131071];     // cart RAM (synthetic)
  reg  [1:0] exp [0:14335];      // expected framebuffer from viewer_model.js
  reg  [1:0] fb  [0:14335];      // captured framebuffer
  reg        wrf [0:14335];      // written flag

  wire [AW-1:0] maddr;
  reg  [7:0]    mdata;
  always @(posedge clk) mdata <= mem[maddr];   // registered 1-cycle read (real BRAM/SDRAM)
  reg           start = 0, rst = 1;
  wire          fb_we, done, busy;
  wire [13:0]   fb_addr;
  wire [1:0]    fb_data;
  integer i, bad, nwr;

  gbcam_photo_decode #(.AW(AW)) dut (
    .clk(clk), .rst(rst), .start(start), .base(20'd0), .slot(5'd0),
    .mem_addr(maddr), .mem_data(mdata),
    .fb_we(fb_we), .fb_addr(fb_addr), .fb_data(fb_data), .busy(busy), .done(done)
  );

  always @(posedge clk) if (fb_we) begin fb[fb_addr] <= fb_data; wrf[fb_addr] <= 1'b1; end

  initial begin
    $readmemh("tb_cartram.hex", mem);
    $readmemh("tb_fb_expected.hex", exp);
    for (i = 0; i < 14336; i = i + 1) wrf[i] = 1'b0;
    @(negedge clk); rst <= 0; @(negedge clk);
    start <= 1; @(negedge clk); start <= 0;
    wait (done); @(posedge clk);
    bad = 0; nwr = 0;
    for (i = 0; i < 14336; i = i + 1) begin
      if (wrf[i]) nwr = nwr + 1;
      if (!wrf[i] || fb[i] !== exp[i]) begin
        bad = bad + 1;
        if (bad <= 5) $display("  mismatch @%0d: got %0d exp %0d written %0b", i, fb[i], exp[i], wrf[i]);
      end
    end
    $display("photo_decode: %0d/14336 pixels written, %0d mismatches", nwr, bad);
    if (bad == 0 && nwr == 14336) $display("*** PHOTO_DECODE PASS ***");
    else                          $display("*** PHOTO_DECODE FAIL ***");
    $finish;
  end
  initial begin #5000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
