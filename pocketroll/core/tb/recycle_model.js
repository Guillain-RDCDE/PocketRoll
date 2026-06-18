// =============================================================================
// recycle_model.js — cycle-accurate JS model of pocketroll_recycle.v
// -----------------------------------------------------------------------------
// A faithful transcription of the Verilog FSM (non-blocking semantics,
// combinational-read / registered-write RAM), so we can validate the recycle
// logic WITHOUT a Verilog simulator (iverilog hangs on this box).
//
// It replays the real "before-del" directory (2 photos), frees gallery slot 1,
// and checks the result against the camera's ground truth (checksum 12 EA).
//
// It also runs with a 5-bit `idx` to demonstrate the overflow bug we caught
// (echo loop needs idx up to 36 > 31) and that 6 bits fixes it.
//
//   node core/tb/recycle_model.js
// =============================================================================
'use strict';

const S = { IDLE:0, FREE:1, SUM_ADDR:2, SUM_ACC:3, WR_SUM:4, WR_XOR:5, ECHO_RD:6, ECHO_WR:7, DONE:8 };
const VEC_START=0x11B2, VEC_LEN=30, VEC_END=VEC_START+VEC_LEN-1;
const CK_SUM=0x11D5, CK_XOR=0x11D6, ECHO_START=0x11D7, BLOCK_LEN=37;
const SUM_SEED=0x2F, XOR_SEED=0x15, DELETED=0xFF;

function run(idxBits) {
  const idxMask = (1 << idxBits) - 1;
  const mem = new Uint8Array(0x12000);

  // ---- preload "before-del": directory 00 01 FF…FF, Magic, checksum 14 14, echo
  mem[0x11B2]=0x00; mem[0x11B3]=0x01;
  for (let a=0x11B4; a<=0x11CF; a++) mem[a]=0xFF;
  [0x4D,0x61,0x67,0x69,0x63].forEach((b,i)=>mem[0x11D0+i]=b);
  mem[0x11D5]=0x14; mem[0x11D6]=0x14;
  for (let i=0;i<37;i++) mem[0x11D7+i]=mem[0x11B2+i];

  // ---- registers
  let state=S.IDLE, idx=0, sum=0, xorv=0, pos=0, done=0;
  let ram_addr=0, ram_wr=0, ram_wr_data=0;
  let start=0, gallery_pos=0;

  function tick() {
    const ram_rd_data = mem[ram_addr];                 // combinational read
    // next-state (RHS evaluated from current values, like non-blocking <=)
    let n_state=state,n_idx=idx,n_sum=sum,n_xorv=xorv,n_pos=pos,n_done=0;
    let n_addr=ram_addr,n_wr=0,n_wd=ram_wr_data;
    switch(state){
      case S.IDLE: if(start){n_pos=gallery_pos; n_state=S.FREE;} break;
      case S.FREE: n_addr=VEC_START+pos; n_wd=0xFF; n_wr=1; n_sum=SUM_SEED; n_xorv=XOR_SEED; n_idx=0; n_state=S.SUM_ADDR; break;
      case S.SUM_ADDR: n_addr=VEC_START+idx; n_state=S.SUM_ACC; break;
      case S.SUM_ACC: n_sum=(sum+ram_rd_data)&0xFF; n_xorv=(xorv^ram_rd_data)&0xFF;
                      if(idx===VEC_LEN-1) n_state=S.WR_SUM; else {n_idx=(idx+1)&idxMask; n_state=S.SUM_ADDR;} break;
      case S.WR_SUM: n_addr=CK_SUM; n_wd=sum; n_wr=1; n_state=S.WR_XOR; break;
      case S.WR_XOR: n_addr=CK_XOR; n_wd=xorv; n_wr=1; n_idx=0; n_state=S.ECHO_RD; break;
      case S.ECHO_RD: n_addr=VEC_START+idx; n_state=S.ECHO_WR; break;
      case S.ECHO_WR: n_addr=ECHO_START+idx; n_wd=ram_rd_data; n_wr=1;
                      if(idx===BLOCK_LEN-1) n_state=S.DONE; else {n_idx=(idx+1)&idxMask; n_state=S.ECHO_RD;} break;
      case S.DONE: n_done=1; n_state=S.IDLE; break;
    }
    if(ram_wr) mem[ram_addr]=ram_wr_data;              // registered write (current values)
    state=n_state; idx=n_idx; sum=n_sum; xorv=n_xorv; pos=n_pos; done=n_done;
    ram_addr=n_addr; ram_wr=n_wr; ram_wr_data=n_wd;
  }

  // ---- drive: pulse start with gallery_pos=1
  gallery_pos=1; start=1; tick(); start=0;
  let cycles=0;
  while(!done && cycles<5000){ tick(); cycles++; }

  const ok = done && cycles<5000;
  const hx=n=>n.toString(16).toUpperCase().padStart(2,'0');
  let pass = ok
    && mem[0x11B2]===0x00 && mem[0x11B3]===0xFF
    && mem[0x11D5]===0x12 && mem[0x11D6]===0xEA;
  for(let i=0;i<37;i++) if(mem[0x11D7+i]!==mem[0x11B2+i]) pass=false;

  return { idxBits, terminated:ok, cycles, dir0:hx(mem[0x11B2]), dir1:hx(mem[0x11B3]),
           cksum:hx(mem[0x11D5])+hx(mem[0x11D6]), pass };
}

for (const bits of [5,6]) {
  const r = run(bits);
  if (!r.terminated)
    console.log(`idx=${bits}-bit : ❌ NON-TERMINATING (idx overflow, looped ${r.cycles}+ cycles) — the bug.`);
  else
    console.log(`idx=${bits}-bit : ${r.pass?'✅ PASS':'❌ FAIL'}  dir=${r.dir0} ${r.dir1}  checksum=${r.cksum}  (${r.cycles} cycles)`);
}
console.log('\nGround truth (camera deletion of slot 1): dir=00 FF, checksum=12EA');
