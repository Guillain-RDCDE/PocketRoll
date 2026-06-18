#!/usr/bin/env node
/**
 * selftest.js — Internal consistency test of gbcam-sav.js (no real cartridge)
 * ============================================================================
 *
 * ⚠️ WHAT THIS TEST PROVES:
 *   The MECHANICS are correct — we build a synthetic save with our own checksum
 *   model, free some slots, and `checkIntegrity` stays true at every step
 *   (checksum + echo recomputed correctly, all the way down to 0 photos).
 *
 * ⚠️ WHAT THIS TEST DOES NOT PROVE:
 *   That our checksum model (seed "Magic"+0x2F+0x15, range 0x11B2..0x11D4,
 *   sum/XOR) is actually THE cartridge's one. Only a `verify` on a REAL .sav
 *   (dumped from a cartridge or an emulator) can confirm that. That is the
 *   remaining validation of Step 2.
 */

'use strict';

const assert = require('assert');
const M = require('./gbcam-sav.js');

let pass = 0;
function ok(cond, msg) { assert(cond, msg); console.log(`  ✓ ${msg}`); pass++; }

// ── Build a consistent synthetic save ───────────────────────────────────────
// 5 active photos (slots 0..4) at the head of the gallery, the rest empty (0xFF).

function makeSave(activeCount) {
  const buf = Buffer.alloc(M.SRAM_SIZE, 0x00);
  for (let i = 0; i < M.VEC_LEN; i++) {
    buf[M.VEC_START + i] = i < activeCount ? i : M.DELETED;
  }
  // Fill bytes 0x11D0..0x11D4 (covered by the checksum) with a non-zero pattern
  for (let a = 0x11D0; a <= 0x11D4; a++) buf[a] = 0xA5;
  // Give each slot a dummy non-empty image (for activeSlots / visual debugging)
  for (let s = 0; s < activeCount; s++) {
    const off = M.PHOTO_DATA_OFFSET + s * M.SLOT_SIZE;
    for (let k = 0; k < 0xE00; k++) buf[off + k] = (s * 7 + k) & 0xFF;
  }
  // Seal: consistent checksum + echo
  const ck = M.computeChecksum(buf);
  buf[M.CK_SUM] = ck.sum; buf[M.CK_XOR] = ck.xor;
  M.mirrorEcho(buf);
  return buf;
}

console.log('selftest gbcam-sav');

// 1. Fresh save: intact
const buf = makeSave(5);
let intg = M.checkIntegrity(buf);
ok(intg.checksumOk, 'synthetic save: consistent checksum');
ok(intg.echoOk,     'synthetic save: consistent echo');
ok(M.activeSlots(buf).length === 5, 'synthetic save: 5 active photos');

// 2. Free a photo by gallery position → -1 active, save still intact
let r = M.freeSlot(buf, 2, 'pos');
ok(r.freedSlot === 2, 'free pos 2 → correctly frees slot 2');
ok(M.activeSlots(buf).length === 4, 'after free: 4 active photos');
intg = M.checkIntegrity(buf);
ok(intg.checksumOk, 'after free: recomputed checksum consistent');
ok(intg.echoOk,     're-copied echo consistent');

// 3. Free by slot number
r = M.freeSlot(buf, 0, 'slot');
ok(r.freedSlot === 0, 'free --slot 0 → frees slot 0');
ok(M.checkIntegrity(buf).checksumOk, 'after free --slot: intact');

// 4. Double-free forbidden (position already empty)
assert.throws(() => M.freeSlot(buf, 2, 'pos'), /already empty/);
ok(true, 'double-free of an empty position rejected');

// 5. The INFINITE LOOP in miniature: emptying the whole gallery stays intact at
//    every iteration — this is the "recycle 30 slots indefinitely" scenario.
const loop = makeSave(M.VEC_LEN); // 30 full
for (let p = 0; p < M.VEC_LEN; p++) {
  M.freeSlot(loop, p, 'pos');
  assert(M.checkIntegrity(loop).checksumOk, `iteration ${p}: checksum broken!`);
}
ok(M.activeSlots(loop).length === 0, 'loop: 30 slots freed one by one, integrity maintained');

console.log(`\n${pass} assertions OK ✅`);
console.log('Still to validate: `verify` on a REAL .sav (actual checksum model).');
