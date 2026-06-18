// Exhaustive scan: for several starting offsets, a rolling CRC32 finalized at
// EVERY position, compared against a target. Finds any range [start..end] whose
// standard CRC32 equals the target.
// Usage: node crc-scan.js <file.sta> [targetHex]
'use strict';
const fs = require('fs');
const sta = fs.readFileSync(process.argv[2]);
const target = process.argv[3] ? (parseInt(process.argv[3]) >>> 0) : sta.readUInt32LE(0x18);
const hex = (n, w = 8) => '0x' + (n >>> 0).toString(16).toUpperCase().padStart(w, '0');

// table CRC32 (zlib)
const T = new Uint32Array(256);
for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1); T[n] = c >>> 0; }

const starts = [0, 0x14, 0x18, 0x1C, 0x20, 0x2C, 0x466C, 0x24418, 0x2466C];
console.log(`Target = ${hex(target)} (field 0x18). Searching for ranges [start..end] with CRC32 = target:\n`);
let found = 0;
for (const s of starts) {
  let c = 0xFFFFFFFF >>> 0;
  for (let i = s; i < sta.length; i++) {
    c = (T[(c ^ sta[i]) & 0xFF] ^ (c >>> 8)) >>> 0;
    const fin = (c ^ 0xFFFFFFFF) >>> 0;          // standard finalization
    if (fin === target) { console.log(`  ✅ standard CRC32: start=${hex(s,6)} end=${hex(i+1,6)} (len ${i+1-s})`); found++; }
    const finNoXor = c >>> 0;                     // without final xor
    if (finNoXor === target) { console.log(`  ✅ CRC32 without final-xor: start=${hex(s,6)} end=${hex(i+1,6)} (len ${i+1-s})`); found++; }
  }
}
if (!found) {
  console.log('  ✗ No range with CRC32 (std or no-xor) = target.');
  console.log('  → 0x18 is probably NOT a CRC32 of the content (different algo, or constant cartridge hash).');
}
