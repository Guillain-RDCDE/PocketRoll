# The infinite roll — resetting the film on the cartridge

*Brick (2) of the dream. [Brick (1), the dump, is here](07-the-dump-saga.md).* Once the photos are
safely on the SD, the film is "full" (30 frames) but every frame is taken. To shoot forever without a
PC, the core has to **blank the roll itself** — right on the cartridge — so the camera sees an empty
film again. This is the other half of "shoot forever, no PC in the field."

---

## 🟢 In plain English

The Game Boy Camera tracks which of its 30 photo slots are used in a tiny **summary table** in
cartridge RAM (bank 0, at `0x11B2`). "Delete all" just marks every entry empty and fixes a checksum —
**the photo pixels are left untouched** (they're already on your SD by then). So "reset the film" =
write 30 "empty" markers + a checksum + a mirror copy. That's it. Do it on the cartridge and the camera
boots to a blank roll.

We already had the muscle for this from the dump: **the core can drive the cartridge bus itself**
(bus-master). Dumping *reads* all 16 banks; resetting *writes* ~74 bytes to bank 0. Same machinery, one
extra mode.

---

## 🔧 The reset recipe (validated in `tools/gbcam-sav.js`)

All in bank 0:

| Region | Address | Write |
|---|---|---|
| Summary (30 slots) | `0x11B2`–`0x11CF` | `0xFF` ×30 (all empty) |
| Checksum | `0x11D5` / `0x11D6` | `0x11` / `0x15` |
| Echo (mirror of `0x11B2`–`0x11D6`) | `0x11D7`–`0x11FB` | the same 37 bytes |

The checksum is `sum = (0x2F + Σ summary) & 0xFF` and `xor = 0x15 ^ (⊕ summary)`, over the summary only.
For 30 bytes of `0xFF`: `sum = 0x11`, `xor = 0x15`. (Σ 30×0xFF = 7650; `(0x2F+7650) mod 256 = 0x11`.
30 is even, so the XOR of thirty `0xFF` is `0x00`, leaving the seed `0x15`.) The "Magic" string at
`0x11D0` is a literal marker — left alone (we rewrite it with the same bytes, harmless).

In hardware this is a 74-byte fold: index `0..73` over `0x11B2..0x11FB`, the second half (`≥0x25`)
mirroring the first — a tiny combinational lookup feeds each byte to a cram write.

## 🎛️ Two buttons, one bus-master

The bus-master FSM gained a mode bit:

- **R1 → READ**: enable RAM, walk all 16 banks → SRAM → dump to SD (sampled at `ce_cpu`, see brick 1).
- **L1 → WRITE**: enable RAM, select bank 0, write the 74 reset bytes → blank roll.

Proof it works — three photos, dumped then reset, read back:

```
R1 then L1, exit, inspect the .sav:
  Active photos : 3 / 30      Summary: 00 01 02      Checksum OK ✅   ← the dump
  (relaunch) gallery empty                                            ← the reset
```

## 🔁 The cycle (and an honest limitation)

```
shoot 30 → R1 (dump → SRAM) → L1 (reset the cartridge) → exit (SRAM → SD) → relaunch (blank roll) → …
```

**Autonomous, no PC.** One catch: to drive the bus we **pause the gb** (gate its clock-enable) while
the rest of the core keeps running — and the gb doesn't cleanly *resume* from an ~80 ms pause; the
screen freezes. So today the flow is **press → exit → relaunch**, not a seamless "keep shooting." In
practice that's fine — you exit to save to SD anyway, and the relaunch is a clean cold boot into the
blank roll. The buttons even register while the screen is frozen (the FSM is independent of the gb).

A truly seamless resume (no relaunch) and unique per-batch filenames (to chain many rolls in one outing
without overwriting the `.sav`) are the next refinements. But the core dream — **a Game Boy Camera with
an endless roll, dumping itself to SD, no computer in sight — works.**
