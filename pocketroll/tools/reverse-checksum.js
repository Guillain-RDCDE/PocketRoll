// Reverse-engineer the summary checksum from a real save.
// Usage: node reverse-checksum.js <sav>
'use strict';
const fs = require('fs');
const buf = fs.readFileSync(process.argv[2]);
const hex = (n, w = 2) => n.toString(16).toUpperCase().padStart(w, '0');

const CK_SUM = 0x11D5, CK_XOR = 0x11D6;
const tSum = buf[CK_SUM], tXor = buf[CK_XOR];
console.log(`Target: sum=0x${hex(tSum)}  xor=0x${hex(tXor)}\n`);

// Prefix sum (mod 256) and prefix xor over the whole file
const N = buf.length;
const P = new Uint32Array(N + 1), X = new Uint8Array(N + 1);
for (let i = 0; i < N; i++) { P[i + 1] = P[i] + buf[i]; X[i + 1] = X[i] ^ buf[i]; }
const rangeSum = (a, b) => (P[b + 1] - P[a]) & 0xFF;   // [a..b] inclusive
const rangeXor = (a, b) => X[b + 1] ^ X[a];

// We look for any range [start..end] whose sum AND xor equal the target.
// end fixed just before the checksum is the most natural hypothesis, but we
// sweep wide. Limited to bank 0 (management area).
const SEARCH_LO = 0x0000, SEARCH_HI = 0x11D4;
const both = [], sumHits = [], xorHits = [];
for (let end = SEARCH_LO; end <= SEARCH_HI; end++) {
  for (let start = SEARCH_LO; start <= end; start++) {
    const s = rangeSum(start, end), x = rangeXor(start, end);
    if (s === tSum && x === tXor) both.push([start, end]);
  }
}

// "Natural" hypotheses: end = 0x11D4 (just before checksum), varying start.
console.log('— Ranges [start..0x11D4] and their (sum,xor) —');
for (const start of [0x11B2, 0x11D0, 0x1000, 0x11B0, 0x11A0]) {
  console.log(`  start=0x${hex(start,4)} : sum=0x${hex(rangeSum(start,0x11D4))} xor=0x${hex(rangeXor(start,0x11D4))}`);
}

console.log(`\n— EXACT ranges (sum==target && xor==target) found: ${both.length} —`);
for (const [a, b] of both.slice(0, 40)) {
  console.log(`  0x${hex(a,4)} .. 0x${hex(b,4)}  (len ${b - a + 1})`);
}
if (both.length > 40) console.log(`  … (${both.length - 40} more)`);
