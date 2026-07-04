// Reference model for the on-board viewer core's decode algorithm.
// 1) Validates our decode against MugDump's gbcam.js on a REAL .sta (local confidence).
// 2) Builds a SYNTHETIC, privacy-safe cart RAM + .sta and emits test vectors + expected
//    framebuffer as $readmemh files for the iverilog testbenches (reproducible, committable).
const fs = require('fs');
const path = require('path');
const OUT = __dirname;

const PHOTO_W = 128, PHOTO_H = 112, TILES_W = 16, TILES_H = 14;
const SLOT = 0x1000, PHOTO_BASE = 0x2000, IMG_BYTES = 0xE00, CART = 131072;

// ── decode (must match gbcam.js exactly) ─────────────────────────────────────
function decodePixel(lo, hi, col) { const b = 7 - col; return (((hi >> b) & 1) << 1) | ((lo >> b) & 1); }
function decodePhoto(cart, base, slot) {
  const off = base + PHOTO_BASE + slot * SLOT;
  const px = new Uint8Array(PHOTO_W * PHOTO_H);
  for (let tr = 0; tr < TILES_H; tr++)
    for (let tc = 0; tc < TILES_W; tc++) {
      const tOff = off + (tr * TILES_W + tc) * 16;
      for (let row = 0; row < 8; row++) {
        const lo = cart[tOff + row * 2], hi = cart[tOff + row * 2 + 1];
        for (let col = 0; col < 8; col++)
          px[(tr * 8 + row) * PHOTO_W + (tc * 8 + col)] = decodePixel(lo, hi, col);
      }
    }
  return px;
}
// ── locate (must match coerceGbCamSave) ──────────────────────────────────────
function locateBase(buf) {
  const isMagic = p => buf[p] === 0x4D && buf[p+1] === 0x61 && buf[p+2] === 0x67 && buf[p+3] === 0x69 && buf[p+4] === 0x63;
  if (buf.length === CART) return 0;
  for (let i = 0x10D2; i + 0xFE + 5 <= buf.length; i++)
    if (isMagic(i) && isMagic(i + 0xFE)) return i - 0x10D2;
  return -1;
}
function summaryOccupied(cart, base) {
  const occ = [];
  for (let i = 0; i < 30; i++) if (cart[base + 0x11B2 + i] !== 0xFF) occ.push(i);
  return occ;
}

let fails = 0;
const ck = (cond, msg) => { if (!cond) { fails++; console.log('  FAIL: ' + msg); } };

// ── (1) cross-check decode vs gbcam.js on a REAL .sta (local only) ────────────
// Both paths are Guillain-local; when absent (fresh clone / CI) this block is skipped
// and only the synthetic, self-contained tests run. Point MUGDUMP_GBCAM / REAL_STA
// env vars at your own files to re-enable the cross-check elsewhere.
const gbcamPath = process.env.MUGDUMP_GBCAM || 'c:/Users/loutr/Dropbox/Perso/GitHub/MugDump/docs/js/gbcam.js';
const realSta   = process.env.REAL_STA      || 'c:/Users/loutr/Dropbox/Perso/GitHub/Open-FGPA-GB-Camera/last3.sta';
if (fs.existsSync(realSta) && fs.existsSync(gbcamPath)) {
  const win = {}; new Function('window', fs.readFileSync(gbcamPath,'utf8'))(win);
  const raw = fs.readFileSync(realSta);
  const buf = new Uint8Array(raw);
  const base = locateBase(buf);
  ck(base >= 0, 'real .sta: Magic base found');
  // build the 128KB cart image the way coerceGbCamSave does, for gbcam.js
  const cart = new Uint8Array(CART).fill(0xFF);
  cart.set(buf.subarray(base, Math.min(buf.length, base + CART)), 0);
  const gb = win.GBCam.parseSav(cart.buffer);
  const occ = summaryOccupied(cart, 0);
  // compare our decode vs gbcam.js for the first occupied slot
  const slot = (gb.photos.find(p => !p.isEmpty) || {}).index;
  if (slot != null) {
    const ours = decodePhoto(cart, 0, slot);
    const theirs = gb.photos[slot].pixels;
    let same = ours.length === theirs.length;
    for (let i = 0; same && i < ours.length; i++) same = ours[i] === theirs[i];
    ck(same, `real .sta: our decode of slot ${slot} matches gbcam.js pixel-for-pixel`);
    console.log(`  real .sta: base=0x${base.toString(16)}, occupied slots=[${occ}], slot ${slot} decode == gbcam.js: ${same}`);
  }
} else {
  console.log('  (real .sta not present — skipping gbcam.js cross-check)');
}

// ── (2) synthetic cart RAM + .sta, deterministic & privacy-safe ───────────────
const cart = new Uint8Array(CART).fill(0x00);
// slot 0 image = deterministic pattern exercising all 4 colours
for (let o = 0; o < IMG_BYTES; o++) cart[PHOTO_BASE + o] = (o * 37 + 11) & 0xFF;
// "Magic" markers at 0x10D2 and 0x11D0 (echo + primary) so locate() works
const MAGIC = [0x4D,0x61,0x67,0x69,0x63];
MAGIC.forEach((b,i) => { cart[0x10D2+i] = b; cart[0x11D0+i] = b; });
// summary vector: slots 0,1,2 used (00 01 02), rest empty (FF)
for (let i = 0; i < 30; i++) cart[0x11B2 + i] = i < 3 ? i : 0xFF;

// wrap into a .sta-like buffer with base offset 0x466C (like a real savestate)
const BASE = 0x466C, STA = BASE + CART + 0x40;
const sta = new Uint8Array(STA).fill(0x5A);
sta.set(cart, BASE);

// self-checks on the model
ck(locateBase(sta) === BASE, `synthetic locate base == 0x${BASE.toString(16)} (got 0x${locateBase(sta).toString(16)})`);
ck(locateBase(cart) === 0, 'raw 128KB save locates at base 0');
ck(JSON.stringify(summaryOccupied(cart,0)) === '[0,1,2]', 'synthetic summary occupied == [0,1,2]');
const fb = decodePhoto(cart, 0, 0); // expected framebuffer for slot 0
// sanity: pattern exercises all 4 shades
ck([0,1,2,3].every(v => fb.includes(v)), 'synthetic slot-0 framebuffer uses all 4 shades');

// ── emit $readmemh vectors for the Verilog testbenches ───────────────────────
const hexBytes = (u8) => Array.from(u8, b => b.toString(16).padStart(2,'0')).join('\n') + '\n';
const hexNib   = (u8) => Array.from(u8, b => b.toString(16)).join('\n') + '\n'; // 1 digit (0..3)
fs.writeFileSync(path.join(OUT,'tb_cartram.hex'), hexBytes(cart));       // 131072 bytes
fs.writeFileSync(path.join(OUT,'tb_sta.hex'), hexBytes(sta));            // STA bytes
fs.writeFileSync(path.join(OUT,'tb_fb_expected.hex'), hexNib(fb));       // 14336 pixels (0..3), 1 digit each
fs.writeFileSync(path.join(OUT,'tb_expected.txt'),
  `BASE=${BASE}\nSTA_LEN=${STA}\nCART_LEN=${CART}\nFB_LEN=${fb.length}\nOCC=${summaryOccupied(cart,0).join(',')}\n`);

console.log(`\nemitted: tb_cartram.hex (${cart.length}), tb_sta.hex (${sta.length}), tb_fb_expected.hex (${fb.length})`);
console.log(fails === 0 ? '\n*** MODEL PASS ***' : `\n*** MODEL FAIL (${fails}) ***`);
process.exit(fails === 0 ? 0 : 1);
