#!/usr/bin/env node
/**
 * gbcam-sav.js — Game Boy Camera save manipulation (.sav, 128 KB)
 * ==========================================================================
 *
 * STEP 2 tool of PocketRoll: prove, in pure software, that we can cleanly
 * "free a slot" (the move that makes the film roll infinite), BEFORE writing
 * a single line of Verilog.
 *
 * No dependencies. Reusable as-is in MugDump.
 *
 * What we manipulate (see docs/01-format-sram-gameboy-camera.md):
 *   - Summary / state vector : 0x11B2..0x11CF (30 bytes, gallery order;
 *     value = slot number, 0xFF = empty/deleted).
 *   - Summary checksum       : 0x11D5 (8-bit sum) + 0x11D6 (8-bit XOR),
 *     computed over 0x11B2..0x11D4, seed "Magic"+0x2F+0x15.
 *   - Echo (backup copy)      : 0x11D7..0x11FB = mirror of 0x11B2..0x11D6.
 *
 * IMPORTANT — the `verify` command is the final arbiter: on an INTACT save,
 * our computed checksum must reproduce, byte for byte, the one stored by the
 * cartridge. If `verify` passes, our model is correct and `free` is safe. If
 * it fails, it's our model (seed/range) that needs adjusting — not the
 * cartridge. This is exactly the empirical validation targeted by Step 2.
 *
 * Usage:
 *   node gbcam-sav.js info   <in.sav>
 *   node gbcam-sav.js verify <in.sav>
 *   node gbcam-sav.js free   <in.sav> <galleryPos> [-o out.sav]
 *   node gbcam-sav.js free   <in.sav> --slot <N>   [-o out.sav]
 */

'use strict';

// ── Format constants (standard USA/EU/JP ROM) ───────────────────────────────

const SRAM_SIZE   = 131072;   // 128 KB
const VEC_START   = 0x11B2;   // summary / state vector
const VEC_LEN     = 30;       // 30 entries (= 30 photo slots)
const VEC_END     = VEC_START + VEC_LEN - 1; // 0x11CF — last byte of the summary
const MAGIC_POS   = 0x11D0;   // "Magic" (4D 61 67 69 63) — literal marker, outside the checksum
const CK_SUM      = 0x11D5;   // left byte: 8-bit sum (seed 0x2F)
const CK_XOR      = 0x11D6;   // right byte: 8-bit XOR (seed 0x15)
const BLOCK_END   = 0x11D6;   // end of the block copied into the echo (inclusive)
const ECHO_START  = 0x11D7;   // start of the echo (mirror of VEC_START..BLOCK_END)
const DELETED     = 0xFF;     // "empty / deleted slot" marker

const SUM_SEED = 0x2F;        // initial value of the sum (reverse-engineered from a real save)
const XOR_SEED = 0x15;        // initial value of the XOR

const PHOTO_DATA_OFFSET = 0x2000; // 1st photo
const SLOT_SIZE         = 0x1000; // size of one photo slot

// ── Checksum ────────────────────────────────────────────────────────────────
//
// Model confirmed on a real Analogue Pocket save:
//   sum = (0x2F + Σ bytes[0x11B2..0x11CF]) mod 256   → 0x11D5
//   xor =  0x15 ^ (⊕ bytes[0x11B2..0x11CF])          → 0x11D6
// The computation covers the SUMMARY ONLY; the "Magic" string at 0x11D0 is a
// literal marker, not checksum data.

function computeChecksum(buf) {
  let sum = SUM_SEED, xor = XOR_SEED;
  for (let a = VEC_START; a <= VEC_END; a++) { sum = (sum + buf[a]) & 0xFF; xor ^= buf[a]; }
  return { sum: sum & 0xFF, xor: xor & 0xFF };
}

// Copy 0x11B2..0x11D6 (summary + checksum) into the echo at 0x11D7+
function mirrorEcho(buf) {
  const len = BLOCK_END - VEC_START + 1; // 37 bytes
  buf.copy(buf, ECHO_START, VEC_START, VEC_START + len);
}

// ── Reading / state ─────────────────────────────────────────────────────────

function readVector(buf) {
  const v = [];
  for (let i = 0; i < VEC_LEN; i++) v.push(buf[VEC_START + i]);
  return v;
}

// Indices of the slots actually in use (value != 0xFF in the summary)
function activeSlots(buf) {
  return readVector(buf).filter(v => v !== DELETED);
}

function checkIntegrity(buf) {
  const stored   = { sum: buf[CK_SUM], xor: buf[CK_XOR] };
  const computed = computeChecksum(buf);
  const checksumOk = stored.sum === computed.sum && stored.xor === computed.xor;

  // The echo must be an exact mirror of 0x11B2..0x11D6
  let echoOk = true;
  const len = BLOCK_END - VEC_START + 1;
  for (let i = 0; i < len; i++) {
    if (buf[VEC_START + i] !== buf[ECHO_START + i]) { echoOk = false; break; }
  }
  return { stored, computed, checksumOk, echoOk };
}

// ── Mutation: free a slot ───────────────────────────────────────────────────
//
// mode 'pos'  : `target` = position in the gallery (0..29) → we reset the
//               matching summary entry to 0xFF.
// mode 'slot' : `target` = physical slot number → we look up the summary entry
//               that points to it and reset it to 0xFF.
// Then: recompute the checksum + re-copy the echo. THE IMAGE IS NOT ERASED
// (it is meant to have already been exported to the SD card).

function freeSlot(buf, target, mode) {
  let vecIndex;
  if (mode === 'slot') {
    vecIndex = readVector(buf).indexOf(target);
    if (vecIndex < 0) throw new Error(`No summary entry points to slot ${target}.`);
  } else {
    vecIndex = target;
    if (vecIndex < 0 || vecIndex >= VEC_LEN) throw new Error(`Gallery position out of bounds: ${target}.`);
    if (buf[VEC_START + vecIndex] === DELETED) throw new Error(`Position ${target} is already empty.`);
  }

  const freedSlot = buf[VEC_START + vecIndex];
  buf[VEC_START + vecIndex] = DELETED;          // 1. mark empty
  const ck = computeChecksum(buf);
  buf[CK_SUM] = ck.sum;                          // 2. recompute the checksum
  buf[CK_XOR] = ck.xor;
  mirrorEcho(buf);                               // 3. re-copy the echo
  return { vecIndex, freedSlot };
}

// ── CLI ─────────────────────────────────────────────────────────────────────

const fs = require('fs');

function loadSav(path) {
  const buf = fs.readFileSync(path);
  if (buf.length !== SRAM_SIZE) {
    console.warn(`[warning] unexpected size: ${buf.length} bytes (expected ${SRAM_SIZE}). Continuing.`);
  }
  return buf;
}

function hex(n, w = 2) { return n.toString(16).toUpperCase().padStart(w, '0'); }

function cmdInfo(path) {
  const buf = loadSav(path);
  const vec = readVector(buf);
  const act = activeSlots(buf);
  const intg = checkIntegrity(buf);

  console.log(`File         : ${path}`);
  console.log(`Size         : ${buf.length} bytes`);
  console.log(`Active photos: ${act.length} / ${VEC_LEN}`);
  console.log(`Summary (0x${hex(VEC_START,4)}) : ${vec.map(v => v === DELETED ? '--' : hex(v)).join(' ')}`);
  console.log(`Stored checksum   : sum=0x${hex(intg.stored.sum)} xor=0x${hex(intg.stored.xor)}`);
  console.log(`Computed checksum : sum=0x${hex(intg.computed.sum)} xor=0x${hex(intg.computed.xor)}`);
  console.log(`Checksum OK       : ${intg.checksumOk ? 'YES ✅' : 'NO ❌ (model needs adjusting)'}`);
  console.log(`Echo consistent   : ${intg.echoOk ? 'YES ✅' : 'NO ❌'}`);
}

function cmdVerify(path) {
  const buf = loadSav(path);
  const intg = checkIntegrity(buf);
  if (intg.checksumOk && intg.echoOk) {
    console.log('✅ verify OK — our checksum model reproduces the cartridge\'s.');
    process.exit(0);
  }
  console.log('❌ verify FAILED:');
  if (!intg.checksumOk) console.log(`   stored checksum (sum=0x${hex(intg.stored.sum)} xor=0x${hex(intg.stored.xor)}) ` +
                                    `≠ computed (sum=0x${hex(intg.computed.sum)} xor=0x${hex(intg.computed.xor)})`);
  if (!intg.echoOk) console.log('   echo inconsistent with the summary.');
  console.log('   → adjust the model (seed/range) in computeChecksum(), NOT the cartridge.');
  process.exit(1);
}

function cmdFree(args) {
  const path = args[0];
  let out = path, mode = 'pos', target = null;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '-o') out = args[++i];
    else if (args[i] === '--slot') { mode = 'slot'; target = parseInt(args[++i], 10); }
    else target = parseInt(args[i], 10);
  }
  if (target === null || Number.isNaN(target)) {
    console.error('Specify a gallery position, or --slot <N>.');
    process.exit(2);
  }
  const buf = loadSav(path);
  const before = activeSlots(buf).length;
  const { vecIndex, freedSlot } = freeSlot(buf, target, mode);
  fs.writeFileSync(out, buf);
  const after = activeSlots(buf).length;
  console.log(`Slot ${freedSlot} freed (summary entry #${vecIndex} → 0xFF).`);
  console.log(`Active photos: ${before} → ${after}. Checksum + echo recomputed.`);
  console.log(`Written: ${out}`);
  console.log('Note: the image is not erased — it is assumed to already be on the SD card.');
}

function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'info':   return cmdInfo(rest[0]);
    case 'verify': return cmdVerify(rest[0]);
    case 'free':   return cmdFree(rest);
    default:
      console.log('Commands: info <sav> | verify <sav> | free <sav> <galleryPos|--slot N> [-o out.sav]');
      process.exit(cmd ? 2 : 0);
  }
}

// Run the CLI only when launched directly (otherwise: reusable module)
if (require.main === module) main();

module.exports = {
  SRAM_SIZE, VEC_START, VEC_LEN, VEC_END, CK_SUM, CK_XOR, DELETED, SUM_SEED, XOR_SEED,
  PHOTO_DATA_OFFSET, SLOT_SIZE,
  computeChecksum, mirrorEcho, readVector, activeSlots, checkIntegrity, freeSlot,
};
