// gbcam_sta_locate — find the Game Boy Camera cart-RAM base inside a loaded buffer
// (a .sta savestate, or a raw .sav where it resolves to base 0). Scans for the
// management-block "Magic" pair: "Magic" at cart-RAM 0x10D2 (echo) and again 0xFE
// later at 0x11D0 (primary). Matches coerceGbCamSave() in gbcam.js / app.js.
//
//   for i = 0x10D2 while i + 0x103 <= len:
//     if mem[i..i+4]=="Magic" and mem[i+0xFE..i+0xFE+4]=="Magic": base = i - 0x10D2
`default_nettype none
module gbcam_sta_locate #(
  parameter AW = 20
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [AW-1:0] len,        // number of valid bytes in the buffer
  output reg  [AW-1:0] mem_addr,
  input  wire [7:0]  mem_data,
  output reg  [AW-1:0] base,
  output reg         found,
  output reg         done,
  output reg         busy
);
  localparam S_IDLE=0, S_RD=1, S_CMP=2, S_ADV=3;
  reg [1:0]  st;
  reg [AW-1:0] i;
  reg [2:0]  k;      // 0..4
  reg        phase;  // 0 = first Magic (@i), 1 = second (@i+0xFE)

  function [7:0] magicbyte(input [2:0] kk);
    case (kk)
      3'd0: magicbyte = 8'h4D; // M
      3'd1: magicbyte = 8'h61; // a
      3'd2: magicbyte = 8'h67; // g
      3'd3: magicbyte = 8'h69; // i
      default: magicbyte = 8'h63; // c
    endcase
  endfunction

  wire [AW-1:0] scan_addr = (phase ? (i + 20'h000FE) : i) + k;

  always @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      st <= S_IDLE; busy <= 1'b0; found <= 1'b0;
    end else case (st)
      S_IDLE: if (start) begin
        i <= 20'h010D2; k <= 0; phase <= 1'b0; found <= 1'b0; busy <= 1'b1; st <= S_RD;
      end
      S_RD:  begin mem_addr <= scan_addr; st <= S_CMP; end
      S_CMP: begin
        if (mem_data == magicbyte(k)) begin
          if (k == 3'd4) begin
            if (phase == 1'b0) begin phase <= 1'b1; k <= 0; st <= S_RD; end  // check 2nd Magic
            else begin base <= i - 20'h010D2; found <= 1'b1; busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
          end else begin k <= k + 1'b1; st <= S_RD; end
        end else st <= S_ADV;   // mismatch → try next i
      end
      S_ADV: begin
        if ((i + 20'h00103) < len) begin i <= i + 1'b1; phase <= 1'b0; k <= 0; st <= S_RD; end
        else begin found <= 1'b0; busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
      end
      default: st <= S_IDLE;
    endcase
  end
endmodule
`default_nettype wire
