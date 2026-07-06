// viewer_top — the on-board viewer's LOGIC CORE (the part that isn't APF/PLL plumbing).
// A budude2-derived core_top instantiates this and connects:
//   • mem_addr/mem_data → the buffer the APF dataslot loaded (SDRAM/BRAM, the .sta/.sav)
//   • load_done/file_len → APF dataslot_allcomplete + slot size
//   • key_next/key_prev  → edge-detected D-pad Right/Left (one-cycle pulses)
//   • video_*            → the openFPGA video outputs
//
// Sequence: on load → sta_locate (find cart-RAM base) → read the 30-byte summary vector
// (which slots hold a photo) → photo_decode the current slot into the framebuffer →
// video_gen rasters it. D-pad steps to the next/prev occupied slot and re-decodes.
//
// STATUS: structural skeleton, elaboration-checked only. sta_locate / photo_decode /
// video_gen are individually simulation-verified; this wiring + the summary/nav FSM are
// NOT hardware-tested yet — that's milestone 1 of the build/flash loop (doc 13 §7).
// Assumes an asynchronous mem read (like the unit testbenches); on a registered BRAM,
// add one wait cycle in the read states.
`default_nettype none
module viewer_top #(parameter AW=20)(
  input  wire        clk,
  input  wire        rst,
  input  wire        load_done,     // pulse: APF finished loading the file
  input  wire [AW-1:0] file_len,
  input  wire        key_next,      // one-cycle pulse (D-pad Right)
  input  wire        key_prev,      // one-cycle pulse (D-pad Left)
  output wire [AW-1:0] mem_addr,
  input  wire [7:0]  mem_data,
  output wire [23:0] video_rgb,
  output wire        video_de,
  output wire        video_hs,
  output wire        video_vs,
  output wire        video_clk,
  output reg  [4:0]  cur_slot,
  output reg  [5:0]  photo_count,
  output reg         ready
);
  localparam S_WAIT=0, S_LOC=1, S_LOCW=2, S_SUMSET=3, S_SUMLAT=4, S_PICK=5,
             S_DEC=6, S_DECW=7, S_SHOW=8;
  reg [3:0] st;

  // ── sta_locate ──────────────────────────────────────────────────────────────
  reg  start_loc;
  wire [AW-1:0] loc_addr, base;
  wire loc_done, loc_found, loc_busy;
  gbcam_sta_locate #(.AW(AW)) u_loc(
    .clk(clk),.rst(rst),.start(start_loc),.len(file_len),
    .mem_addr(loc_addr),.mem_data(mem_data),.base(base),.found(loc_found),.done(loc_done),.busy(loc_busy));
  reg [AW-1:0] base_r;

  // ── photo_decode → framebuffer ───────────────────────────────────────────────
  reg  start_dec;
  wire [AW-1:0] dec_addr;
  wire dec_we; wire [13:0] dec_waddr; wire [1:0] dec_wdata; wire dec_done, dec_busy;
  gbcam_photo_decode #(.AW(AW)) u_dec(
    .clk(clk),.rst(rst),.start(start_dec),.base(base_r),.slot(cur_slot),
    .mem_addr(dec_addr),.mem_data(mem_data),
    .fb_we(dec_we),.fb_addr(dec_waddr),.fb_data(dec_wdata),.busy(dec_busy),.done(dec_done));

  // ── framebuffer + video ──────────────────────────────────────────────────────
  wire [14:0] vid_raddr; wire [1:0] vid_rdata;
  framebuffer #(.DEPTH(14336),.AW(15)) u_fb(
    .clk(clk),.we(dec_we),.waddr({1'b0,dec_waddr}),.wdata(dec_wdata),
    .raddr(vid_raddr),.rdata(vid_rdata));
  video_gen #(.IMG_X(16),.IMG_Y(16),.IMG_W(128),.IMG_H(112),.FB_STRIDE(128),.AW(15)) u_vid(
    .clk(clk),.rst(rst),.fb_addr(vid_raddr),.fb_data(vid_rdata),
    .video_rgb(video_rgb),.video_de(video_de),.video_hs(video_hs),.video_vs(video_vs),.video_clk(video_clk));

  // ── summary vector (occupancy) ────────────────────────────────────────────────
  reg [29:0] occ;
  reg [4:0]  si;                  // summary index 0..29
  reg [AW-1:0] sum_addr;

  // mem port arbitration
  assign mem_addr = (st==S_LOC || st==S_LOCW) ? loc_addr :
                    (st==S_SUMSET || st==S_SUMLAT) ? sum_addr :
                    (st==S_DEC || st==S_DECW) ? dec_addr : {AW{1'b0}};

  // next/prev occupied slot (combinational scan of occ, wrapping over 30)
  function [4:0] step_occ(input [29:0] o, input [4:0] cur, input fwd);
    integer k; reg [4:0] cand; reg found;
    begin
      step_occ = cur; found = 1'b0;
      for (k=1; k<=30; k=k+1) begin
        cand = fwd ? ((cur + k) % 30) : ((cur + 30 - k) % 30);
        if (!found && o[cand]) begin step_occ = cand; found = 1'b1; end
      end
    end
  endfunction

  integer b;
  always @(posedge clk) begin
    start_loc <= 1'b0;
    start_dec <= 1'b0;
    if (rst) begin
      st<=S_WAIT; ready<=1'b0; occ<=30'd0; photo_count<=6'd0; cur_slot<=5'd0;
    end else case (st)
      S_WAIT:   if (load_done) begin ready<=1'b0; start_loc<=1'b1; st<=S_LOC; end
      S_LOC:    st<=S_LOCW;                       // start pulsed; wait for done
      S_LOCW:   if (loc_done) begin
                  if (loc_found) begin base_r<=base; si<=0; occ<=0; st<=S_SUMSET; end
                  else st<=S_WAIT;                // no cart RAM found → idle
                end
      S_SUMSET: begin sum_addr <= base_r + 20'h011B2 + si; st<=S_SUMLAT; end
      S_SUMLAT: begin
                  occ[si] <= (mem_data != 8'hFF); // slot used if summary byte != 0xFF
                  if (si==5'd29) st<=S_PICK; else begin si<=si+1'b1; st<=S_SUMSET; end
                end
      S_PICK:   begin
                  photo_count <= occ[0]+occ[1]+occ[2]+occ[3]+occ[4]+occ[5]+occ[6]+occ[7]+occ[8]+occ[9]
                               + occ[10]+occ[11]+occ[12]+occ[13]+occ[14]+occ[15]+occ[16]+occ[17]+occ[18]+occ[19]
                               + occ[20]+occ[21]+occ[22]+occ[23]+occ[24]+occ[25]+occ[26]+occ[27]+occ[28]+occ[29];
                  cur_slot <= step_occ(occ, 5'd29, 1'b1); // first occupied slot (start scan after wrap)
                  st <= S_DEC;
                end
      S_DEC:    begin start_dec<=1'b1; st<=S_DECW; end
      S_DECW:   if (dec_done) begin ready<=1'b1; st<=S_SHOW; end
      S_SHOW:   begin
                  if (key_next) begin cur_slot<=step_occ(occ,cur_slot,1'b1); st<=S_DEC; end
                  else if (key_prev) begin cur_slot<=step_occ(occ,cur_slot,1'b0); st<=S_DEC; end
                end
      default:  st<=S_WAIT;
    endcase
  end
endmodule
`default_nettype wire
