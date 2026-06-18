// Locate the 128 KB of Game Boy Camera SRAM inside a .sta save state
// Usage: node find-sram-in-sta.js <real.sav> <real.sta>
'use strict';
const fs = require('fs');
const sav = fs.readFileSync(process.argv[2]);
const sta = fs.readFileSync(process.argv[3]);
const hex = (n, w = 6) => '0x' + n.toString(16).toUpperCase().padStart(w, '0');

console.log(`sav: ${sav.length} bytes   sta: ${sta.length} bytes   (delta ${sta.length - sav.length})`);

// Distinctive fingerprint: the management area 0x11B2..0x11FB (summary+Magic+checksum+echo)
const SIG_OFF = 0x11B2, SIG_LEN = 0x4A; // 74 very specific bytes
const sig = sav.subarray(SIG_OFF, SIG_OFF + SIG_LEN);

// Search for the signature in the .sta
const idx = sta.indexOf(sig);
if (idx < 0) {
  console.log('Management signature NOT found as-is in the .sta.');
  console.log('→ SRAM may be compressed/interleaved. Trying the "Magic" string (4D 61 67 69 63):');
  const magic = Buffer.from([0x4D,0x61,0x67,0x69,0x63]);
  let p = -1, hits = [];
  while ((p = sta.indexOf(magic, p + 1)) !== -1) hits.push(p);
  console.log('  occurrences of "Magic" in the .sta:', hits.map(hex).join(', ') || '(none)');
  process.exit(0);
}

// The embedded SRAM therefore starts at idx - 0x11B2
const sramStart = idx - SIG_OFF;
console.log(`✅ Management area found at ${hex(idx)} → embedded SRAM at ${hex(sramStart)}`);

// Verify that the whole 128 KB block matches byte for byte
let mism = 0, first = -1;
for (let i = 0; i < sav.length; i++) {
  if (sta[sramStart + i] !== sav[i]) { if (first < 0) first = i; mism++; }
}
if (mism === 0) {
  console.log(`✅ All 131072 SRAM bytes match exactly (contiguous, uncompressed SRAM).`);
  console.log(`   → to edit the .sta: apply the recipe at the same offset + ${hex(sramStart)}.`);
} else {
  console.log(`⚠️ ${mism} bytes differ (1st at +${hex(first)}). SRAM may be partial/reordered in the .sta.`);
}
