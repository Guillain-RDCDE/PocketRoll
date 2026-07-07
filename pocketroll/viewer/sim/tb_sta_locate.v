`timescale 1ns/1ps
`default_nettype none
module tb_sta_locate;
  localparam AW = 20;
  reg clk = 0; always #5 clk = ~clk;

  reg  [7:0] mem [0:262143];
  wire [AW-1:0] maddr;
  reg  [7:0]    mdata;
  always @(posedge clk) mdata <= mem[maddr];   // registered 1-cycle read (real BRAM/SDRAM)
  reg           start = 0, rst = 1;
  reg  [AW-1:0] len;
  wire [AW-1:0] base;
  wire          found, done, busy;
  integer f, pass;

  gbcam_sta_locate #(.AW(AW)) dut (
    .clk(clk), .rst(rst), .start(start), .len(len),
    .mem_addr(maddr), .mem_data(mdata), .base(base), .found(found), .done(done), .busy(busy)
  );

  task run_case(input [AW-1:0] L, input [AW-1:0] expect_base);
    begin
      len = L;
      @(negedge clk); rst <= 1; @(negedge clk); rst <= 0; @(negedge clk);
      start <= 1; @(negedge clk); start <= 0;
      wait (done); @(posedge clk);
      $display("  found=%0b base=0x%0h (expect 0x%0h)", found, base, expect_base);
      if (found && base === expect_base) pass = pass + 1;
      else $display("  -> CASE FAIL");
    end
  endtask

  initial begin
    pass = 0;
    // Case 1: synthetic .sta, cart at base 0x466C
    for (f = 0; f < 262144; f = f + 1) mem[f] = 8'h5A;
    $readmemh("tb_sta.hex", mem);
    run_case(20'd149164, 20'h0466C);
    // Case 2: raw 128 KB cart save → base 0
    for (f = 0; f < 262144; f = f + 1) mem[f] = 8'h00;
    $readmemh("tb_cartram.hex", mem);
    run_case(20'd131072, 20'h00000);
    $display("sta_locate: %0d/2 cases passed", pass);
    if (pass == 2) $display("*** STA_LOCATE PASS ***");
    else           $display("*** STA_LOCATE FAIL ***");
    $finish;
  end
  initial begin #40000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
