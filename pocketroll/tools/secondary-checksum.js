// Crack the secondary checksum (0x10D7/0x11B0) from 2 real saves.
// Usage: node secondary-checksum.js <before.sav> <after.sav>
'use strict';
const fs = require('fs');
const B = fs.readFileSync(process.argv[2]); // before-del (2 photos)
const A = fs.readFileSync(process.argv[3]); // after-del  (1 photo)
const hx = (n, w = 2) => n.toString(16).toUpperCase().padStart(w, '0');

// Context around byte 0x10BD and its echo 0x1196
function ctx(buf, label) {
  console.log(`\n[${label}]`);
  for (const base of [0x10B8, 0x10D4, 0x1190, 0x11AE]) {
    let s = `  0x${base.toString(16).toUpperCase()} : `;
    for (let i = 0; i < 12; i++) s += hx(buf[base + i]) + ' ';
    console.log(s);
  }
}
ctx(B, 'before-del (2 photos)');
ctx(A, 'after-del  (1 photo)');

// The primary checksum is at 0x10D7(lo)/0x10D8(hi). Stored:
console.log(`\nPrimary checksum 0x10D7-8 : before=${hx(B[0x10D7])}${hx(B[0x10D8])}  after=${hx(A[0x10D7])}${hx(A[0x10D8])}`);
console.log(`Echo checksum    0x11B0-1 : before=${hx(B[0x11B0])}${hx(B[0x11B1])}  after=${hx(A[0x11B0])}${hx(A[0x11B1])}`);

// Brute force: find (start,end,seedSum,seedXor) such that for BOTH saves,
// sum8(range)+seed == byte[0x10D7] and xor8(range)^seed == byte[0x10D8].
// We sweep plausible ranges around 0x1000..0x10D6.
function sum8(buf,s,e){let x=0;for(let i=s;i<e;i++)x=(x+buf[i])&0xFF;return x;}
function xor8(buf,s,e){let x=0;for(let i=s;i<e;i++)x^=buf[i];return x;}

const POS_SUM = 0x10D7, POS_XOR = 0x10D8;
let hits = [];
for (let start = 0x1000; start <= 0x10C0; start++) {
  for (let end = 0x10C0; end <= 0x10D7; end++) {   // end exclusive
    const sB = sum8(B,start,end), sA = sum8(A,start,end);
    const xB = xor8(B,start,end), xA = xor8(A,start,end);
    // seed_sum must be identical for B and A
    const seedSumB = (B[POS_SUM] - sB) & 0xFF, seedSumA = (A[POS_SUM] - sA) & 0xFF;
    const seedXorB = (B[POS_XOR] ^ xB),        seedXorA = (A[POS_XOR] ^ xA);
    if (seedSumB === seedSumA && seedXorB === seedXorA) {
      hits.push({start, end, seedSum: seedSumB, seedXor: seedXorB});
    }
  }
}
console.log(`\nModels (start,end,seedSum,seedXor) consistent across both saves: ${hits.length}`);
for (const h of hits.slice(0, 20))
  console.log(`  start=0x${h.start.toString(16)} end=0x${h.end.toString(16)} seedSum=0x${hx(h.seedSum)} seedXor=0x${hx(h.seedXor)}`);
if (hits.length > 20) console.log(`  …(${hits.length-20} more)`);
