// Inspect the structure of an Analogue Pocket .sta save state.
// Usage: node dump-sta.js <file.sta> [sramOffset]
'use strict';
const fs = require('fs');
const sta = fs.readFileSync(process.argv[2]);
const sramOff = process.argv[3] ? parseInt(process.argv[3]) : 0x466C;
const hex = (n, w = 6) => '0x' + n.toString(16).toUpperCase().padStart(w, '0');

function dump(base, len, label) {
  console.log(`\n--- ${label} (${hex(base)}..${hex(base + len - 1)}) ---`);
  for (let r = 0; r < len; r += 16) {
    let h = '', a = '';
    for (let i = 0; i < 16 && r + i < len; i++) {
      const b = sta[base + r + i];
      h += b.toString(16).toUpperCase().padStart(2, '0') + ' ';
      a += (b >= 32 && b < 127) ? String.fromCharCode(b) : '.';
    }
    console.log(`${hex(base + r)} : ${h.padEnd(48)} ${a}`);
  }
}

console.log(`Size: ${sta.length} bytes (${hex(sta.length)})`);
dump(0x00, 0x60, 'HEADER');
dump(sramOff - 0x20, 0x30, 'BEFORE the SRAM block (APF descriptor?)');
dump(sta.length - 0x40, 0x40, 'FOOTER (global checksum?)');

// The APF marker spotted by pokepocket
const marker = Buffer.from('a0003001000c0000a0003001000c0001', 'hex');
const mi = sta.indexOf(marker);
console.log(`\nAPF marker 'a0003001000c0000…': ${mi >= 0 ? hex(mi) : 'absent'}`);

// All "a0003001" patterns (data slot descriptors?)
const ds = Buffer.from('a0003001', 'hex');
let p = -1, hits = [];
while ((p = sta.indexOf(ds, p + 1)) !== -1) hits.push(p);
console.log(`Descriptors 'a0003001': ${hits.length} →`, hits.slice(0, 12).map(hex).join(' '));

// Standard CRC32 of the whole file WITHOUT the last 4 bytes, to compare against the footer
function crc32(buf, start, end) {
  let c = ~0 >>> 0;
  for (let i = start; i < end; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
  }
  return (~c) >>> 0;
}
const tailLE = sta.readUInt32LE(sta.length - 4);
const tailBE = sta.readUInt32BE(sta.length - 4);
console.log(`\nFooter last 4 bytes: LE=${hex(tailLE,8)}  BE=${hex(tailBE,8)}`);
console.log(`CRC32(0..len-4)       : ${hex(crc32(sta,0,sta.length-4),8)}`);
console.log(`CRC32(0..len)         : ${hex(crc32(sta,0,sta.length),8)}`);
