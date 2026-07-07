// gbcam_photo_decode — decode one Game Boy Camera photo slot into a 128x112 2bpp
// framebuffer. Reads the cart RAM as a byte memory with a REGISTERED 1-cycle read
// latency (real BRAM/SDRAM: data valid the cycle after the address is presented),
// writes one framebuffer pixel per cycle. Matches MugDump's gbcam.js decode exactly
// (verified pixel-for-pixel by viewer_model.js against a real .sta).
//
//   photo image = 16x14 tiles, tile = 8 rows x [lo,hi], pixel = {hi[7-col], lo[7-col]}
//   byte addr   = base + 0x2000 + slot*0x1000 + (tile_row*16 + tile_col)*16 + row*2
//   fb  addr    = (tile_row*8 + row)*128 + (tile_col*8 + col)
`default_nettype none
module gbcam_photo_decode #(
  parameter AW = 20                 // cart byte-address width
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        start,         // pulse: begin decoding
  input  wire [AW-1:0] base,        // cart-RAM base offset within the loaded buffer
  input  wire [4:0]  slot,          // 0..29
  // synchronous byte-memory read port (data valid 1 cycle after addr)
  output reg  [AW-1:0] mem_addr,
  input  wire [7:0]  mem_data,
  // framebuffer write port (14336 entries, 2 bits each)
  output reg         fb_we,
  output reg  [13:0] fb_addr,
  output reg  [1:0]  fb_data,
  output reg         busy,
  output reg         done
);
  // pipelined for 1-cycle registered read: set lo addr, set hi addr, latch lo, latch hi, write
  localparam S_IDLE=0, S_RDLO=1, S_RDHI=2, S_LATLO=3, S_LATHI=4, S_WR=5, S_DONE=6;
  reg [2:0]  st;
  reg [3:0]  trow;   // 0..13
  reg [3:0]  tcol;   // 0..15
  reg [2:0]  row;    // 0..7
  reg [2:0]  col;    // 0..7
  reg [7:0]  lo, hi;

  // byte address of the current tile row's low byte
  wire [7:0]  tindex   = trow*16 + tcol;                 // 0..223
  wire [AW-1:0] tbase  = base + 20'h02000 + (slot<<12) + (tindex<<4);
  wire [AW-1:0] lo_addr = tbase + (row<<1);
  wire [13:0] pix_addr  = ((trow*8 + row) <<7) + (tcol*8 + col);
  wire [2:0]  b = 7 - col;
  wire [1:0]  pixel = { hi[b], lo[b] };   // {hi[7-col], lo[7-col]}

  always @(posedge clk) begin
    fb_we <= 1'b0;
    done  <= 1'b0;
    if (rst) begin
      st <= S_IDLE; busy <= 1'b0;
    end else case (st)
      S_IDLE:  if (start) begin trow<=0; tcol<=0; row<=0; col<=0; busy<=1'b1; st<=S_RDLO; end
      S_RDLO:  begin mem_addr <= lo_addr;         st <= S_RDHI;  end  // present lo addr
      S_RDHI:  begin mem_addr <= lo_addr + 1'b1;  st <= S_LATLO; end  // present hi addr (lo data en route)
      S_LATLO: begin lo <= mem_data;              st <= S_LATHI; end  // lo valid now
      S_LATHI: begin hi <= mem_data; col <= 0;    st <= S_WR;    end  // hi valid now
      S_WR: begin
        fb_we   <= 1'b1;
        fb_addr <= pix_addr;
        fb_data <= pixel;
        if (col == 3'd7) begin
          if (row == 3'd7) begin
            row <= 0;
            if (tcol == 4'd15) begin
              tcol <= 0;
              if (trow == 4'd13) st <= S_DONE;
              else begin trow <= trow + 1'b1; st <= S_RDLO; end
            end else begin tcol <= tcol + 1'b1; st <= S_RDLO; end
          end else begin row <= row + 1'b1; st <= S_RDLO; end
        end else col <= col + 1'b1;   // stay in S_WR, next pixel
      end
      S_DONE:  begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
      default: st <= S_IDLE;
    endcase
  end
endmodule
`default_nettype wire
