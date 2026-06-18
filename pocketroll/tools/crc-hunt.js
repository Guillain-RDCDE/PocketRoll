// Find which CRC/sum, over which range, reproduces field 0x18 of the .sta.
// Usage: node crc-hunt.js <file.sta> [sramOffset]
'use strict';
const fs = require('fs');
const sta = fs.readFileSync(process.argv[2]);
const SRAM = process.argv[3] ? parseInt(process.argv[3]) : 0x466C;
const SRAM_LEN = 0x20000; // 128 KB
const hex = (n, w = 8) => '0x' + (n >>> 0).toString(16).toUpperCase().padStart(w, '0');

const h14 = sta.readUInt32LE(0x14); // cartridge serial (ROM CRC)
const h18 = sta.readUInt32LE(0x18); // probable target
const h04 = sta.readUInt32LE(0x04);
const h08 = sta.readUInt32LE(0x08);
console.log(`Header fields: 0x04=${hex(h04)} 0x08=${hex(h08)} 0x14=${hex(h14)}(serial) 0x18=${hex(h18)}(target)`);
console.log(`SRAM @ ${hex(SRAM,6)} .. ${hex(SRAM+SRAM_LEN,6)}  (does end coincide with 0x08? ${SRAM+SRAM_LEN===h08})\n`);

// --- CRC32 variants ---
function crc32(buf, s, e, { poly = 0xEDB88320, init = 0xFFFFFFFF, xorout = 0xFFFFFFFF, refin = true } = {}) {
  let c = init >>> 0;
  for (let i = s; i < e; i++) {
    let b = buf[i];
    if (!refin) { // non-reflected version (normal poly) — rare here, we keep the reflected one by default
      c ^= (b << 24);
      for (let k = 0; k < 8; k++) c = (c & 0x80000000) ? ((c << 1) ^ 0x04C11DB7) >>> 0 : (c << 1) >>> 0;
      continue;
    }
    c ^= b;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (poly & -(c & 1));
  }
  return ((c ^ xorout) >>> 0);
}
function sum32(buf, s, e) { let x = 0; for (let i = s; i < e; i++) x = (x + buf[i]) >>> 0; return x >>> 0; }

const ranges = {
  'SRAM 128KB (0x466C..+0x20000)': [SRAM, SRAM + SRAM_LEN],
  'SRAM 131072 exact'            : [SRAM, SRAM + 131072],
  'from 0x08-ptr data start'     : [h08, sta.length],
  'everything after header 0x20' : [0x20, sta.length],
  'everything after 0x2C'        : [0x2C, sta.length],
  'whole file'                   : [0, sta.length],
  'SRAM..end'                    : [SRAM, sta.length],
  '0x04ptr..0x08ptr'             : [h04, h08],
};

console.log('Comparison against field 0x18 =', hex(h18), ':\n');
for (const [name, [s, e]] of Object.entries(ranges)) {
  if (s < 0 || e > sta.length || s >= e) { console.log(`  ${name.padEnd(34)} (invalid range)`); continue; }
  const std  = crc32(sta, s, e);
  const noxor= crc32(sta, s, e, { xorout: 0 });
  const noinit=crc32(sta, s, e, { init: 0, xorout: 0 });
  const sm   = sum32(sta, s, e);
  const mark = v => (v >>> 0) === h18 ? '   <== MATCH !!' : '';
  console.log(`  ${name.padEnd(34)} crc32=${hex(std)}${mark(std)}  crc(no-xor)=${hex(noxor)}${mark(noxor)}  crc(0init)=${hex(noinit)}${mark(noinit)}  sum=${hex(sm)}${mark(sm)}`);
}
