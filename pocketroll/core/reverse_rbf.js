// =============================================================================
// reverse_rbf.js — turn a Quartus .rbf into the Analogue Pocket .rbf_r
// -----------------------------------------------------------------------------
// openFPGA cores load a BIT-REVERSED raw bitstream (each byte's bits flipped
// MSB<->LSB). After a Quartus compile produces output_files/ap_core.rbf, run:
//
//   node core/reverse_rbf.js <fork>/src/output_files/ap_core.rbf <fork>/pkg/gb/Cores/budude2.GB/gb.rbf_r
//
// (the output name must match "filename" in core.json — here gb.rbf_r)
// =============================================================================
'use strict';
const fs = require('fs');
const [inp, out] = process.argv.slice(2);
if (!inp || !out) { console.error('usage: node reverse_rbf.js <in.rbf> <out.rbf_r>'); process.exit(2); }

// bit-reverse lookup table for a byte
const rev = new Uint8Array(256);
for (let i = 0; i < 256; i++) { let b = i, r = 0; for (let k = 0; k < 8; k++) { r = (r << 1) | (b & 1); b >>= 1; } rev[i] = r; }

const src = fs.readFileSync(inp);
const dst = Buffer.allocUnsafe(src.length);
for (let i = 0; i < src.length; i++) dst[i] = rev[src[i]];
fs.writeFileSync(out, dst);
console.log(`Reversed ${src.length} bytes → ${out}`);
