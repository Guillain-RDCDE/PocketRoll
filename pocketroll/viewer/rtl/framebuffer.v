// framebuffer — 128×112 (14336) × 2bpp dual-port store: photo_decode writes, video_gen
// reads. Read is asynchronous to match video_gen's current assumption; on a real BRAM
// with registered read, add one pipeline stage in video_gen (see README).
`default_nettype none
module framebuffer #(parameter DEPTH=14336, AW=15)(
  input  wire        clk,
  input  wire        we,
  input  wire [AW-1:0] waddr,
  input  wire [1:0]  wdata,
  input  wire [AW-1:0] raddr,
  output wire [1:0]  rdata
);
  reg [1:0] mem [0:DEPTH-1];
  always @(posedge clk) if (we) mem[waddr] <= wdata;
  assign rdata = mem[raddr];
endmodule
`default_nettype wire
