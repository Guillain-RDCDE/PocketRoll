// Apply the "free a slot" recipe to the SRAM embedded in a .sta save state
// Usage: node edit-sta.js <in.sta> <ref.sav> <galleryPos> <out.sta>
//
// We locate the SRAM via a 74-byte SIGNATURE (the management area of the
// reference .sav) — reliable, unlike the "Magic" string alone, which appears
// several times in the save state (summary, echo, WRAM working copy…).
'use strict';
const fs = require('fs');
const M = require('./gbcam-sav.js');

const [inPath, refPath, posStr, outPath] = process.argv.slice(2);
const pos = parseInt(posStr, 10);

const sta = fs.readFileSync(inPath);
const ref = fs.readFileSync(refPath);

// Signature = management area 0x11B2..+0x4A of the reference .sav (74 very specific bytes)
const SIG_OFF = 0x11B2, SIG_LEN = 0x4A;
const sig = ref.subarray(SIG_OFF, SIG_OFF + SIG_LEN);
const idx = sta.indexOf(sig);
if (idx < 0) throw new Error('Management signature not found in the .sta.');
const sramStart = idx - SIG_OFF;
console.log(`Embedded SRAM at 0x${sramStart.toString(16).toUpperCase()}`);

// Sanity: the 131072 bytes must match the reference
let mism = 0;
for (let i = 0; i < M.SRAM_SIZE; i++) if (sta[sramStart + i] !== ref[i]) mism++;
if (mism) throw new Error(`SRAM block differs (${mism} bytes) — suspect offset, aborting.`);
console.log('128 KB SRAM block verified identical to the reference ✅');

// Direct view (subarray shares memory → in-place mutation in the .sta)
const sram = sta.subarray(sramStart, sramStart + M.SRAM_SIZE);
console.log(`Before: ${M.activeSlots(sram).length} photos, checksum ${M.checkIntegrity(sram).checksumOk ? 'OK' : 'KO'}`);

const r = M.freeSlot(sram, pos, 'pos');
const ok = M.checkIntegrity(sram).checksumOk;
console.log(`Slot ${r.freedSlot} freed → ${M.activeSlots(sram).length} photos, checksum ${ok ? 'OK ✅' : 'KO ❌'}`);

fs.writeFileSync(outPath, sta);
console.log(`Written: ${outPath}`);
console.log('⚠️ Only the .sta\'s SRAM (cartridge) is edited. If the displayed gallery comes');
console.log('   from a WRAM copy of the snapshot, or if the .sta has a global checksum,');
console.log('   the result may differ — your test on the Pocket will settle it.');
