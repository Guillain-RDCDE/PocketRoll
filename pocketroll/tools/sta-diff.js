// Diff two .sta save states (with their reference .sav files) to isolate the
// validation field that follows the SRAM content.
// Usage: node sta-diff.js <A.sta> <A.sav> <B.sta> <B.sav>
'use strict';
const fs = require('fs');
const M = require('./gbcam-sav.js');
const hex = (n, w = 8) => '0x' + (n >>> 0).toString(16).toUpperCase().padStart(w, '0');

function load(staPath, savPath) {
  const sta = fs.readFileSync(staPath), sav = fs.readFileSync(savPath);
  const sig = sav.subarray(0x11B2, 0x11B2 + 0x4A);
  const sramOff = sta.indexOf(sig) - 0x11B2;
  return { sta, sav, sramOff, path: staPath };
}

const A = load(process.argv[2], process.argv[3]);
const B = load(process.argv[4], process.argv[5]);

console.log(`A=${process.argv[2].split(/[\\/]/).pop()}  SRAM@${hex(A.sramOff,6)}`);
console.log(`B=${process.argv[4].split(/[\\/]/).pop()}  SRAM@${hex(B.sramOff,6)}\n`);

// 1) Header fields side by side
console.log('--- Header fields (0x00..0x2B) ---');
for (let off = 0; off < 0x2C; off += 4) {
  const a = A.sta.readUInt32LE(off), b = B.sta.readUInt32LE(off);
  console.log(`  0x${off.toString(16).padStart(2,'0')} : A=${hex(a)}  B=${hex(b)}  ${a!==b?'<<< DIFF':''}`);
}

// 2) Map of differences by zone
function diffCount(a, b, s, e) { let n = 0, first = -1; for (let i = s; i < e; i++) if (a[i] !== b[i]) { if (first<0) first=i; n++; } return { n, first }; }
const L = Math.min(A.sta.length, B.sta.length);
console.log('\n--- Differences by zone (bytes that change A→B) ---');
const zones = [
  ['header 0x00..0x2C', 0x00, 0x2C],
  ['pre-SRAM 0x2C..SRAM', 0x2C, A.sramOff],
  ['SRAM 128KB', A.sramOff, A.sramOff + 0x20000],
  ['post-SRAM', A.sramOff + 0x20000, L],
];
for (const [name, s, e] of zones) {
  const d = diffCount(A.sta, B.sta, s, e);
  console.log(`  ${name.padEnd(22)} : ${d.n} bytes differ ${d.first>=0?'(1st at '+hex(d.first,6)+')':''}`);
}

// 3) Detail of the diffs in the pre-SRAM zone (where a checksum/length would live)
console.log('\n--- Diff detail header + pre-SRAM (outside SRAM) ---');
let shown = 0;
for (let i = 0; i < A.sramOff && shown < 40; i++) {
  if (A.sta[i] !== B.sta[i]) {
    console.log(`  ${hex(i,6)} : A=${A.sta[i].toString(16).padStart(2,'0')}  B=${B.sta[i].toString(16).padStart(2,'0')}`);
    shown++;
  }
}
if (shown === 0) console.log('  (no difference outside SRAM — the entire delta is within the SRAM)');
