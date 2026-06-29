# PocketRoll — ROM disassembly: the "film full" routine, located & patchable

*The reverse-engineering result behind doc 10 §7 step 1. We disassembled the retail Game Boy Camera
ROM ourselves (no public disassembly of this logic exists) and located the exact routines, addresses,
and bytes for the cyclic-overwrite grail patch — plus the checksum algorithm needed to avoid the
suicide-wipe.*

---

## 0. TL;DR

- **No public commented disassembly** of the retail GB Camera photo-management logic exists (deep
  research, 19 verified claims). The save *format* is fully documented (Boichot); the *ROM code* was
  not — so we disassembled it.
- **All photo/directory management lives in ROM bank `$02`**, and the offsets are **identical between
  the US "GAMEBOYCAMERA" and JP "POCKETCAMERA (V1.1)" ROMs** → these are the canonical routines.
- We found the **free-slot scan**, the three **"find a free slot" call sites**, the **"film full"
  refusal branch**, the **directory-blank+checksum writer**, the **checksum algorithm**, and the
  **WRAM working copy** of the directory.
- **The grail patch is ~3 bytes**: neutralise the "full → bail" branch at the photo-capture site so
  the camera writes the new photo into the slot the scan already returns (`A=0`) instead of refusing.

ROMs analysed (local): `pocketroll/samples/emutest-original/gbcam.gb` (US, 1 MB, type `$FC`, 64 banks)
and `Pocket Camera (J) (V1.1) [S].gb` (JP). Tooling: our own scanner + mini LR35902 disassembler
(`scratchpad/gbcam-re/scan.py`), no external disassembler needed.

---

## 1. Address map (all in ROM bank `$02`, CPU window `$4000–$7FFF`)

The directory vector at SRAM offset `0x11B2` is mapped to CPU **`$B1B2`** (`$A000 + 0x11B2`, SRAM
bank 0). The camera keeps a **WRAM working copy at `$D563`** and syncs it to SRAM.

| Routine | Bank:CPU | foff | What it does |
|---|---|---|---|
| **Free-slot scan** | `02:444D` | `0x00844D` | Scans 30 bytes at `$D563` for value == `A`. Returns `A`=slot index (0-based) + **carry clear** if found; `A=0` + **carry SET** if none (= "full"). |
| **"Find free slot" sites** (×3) | `02:45A4`, `02:463B`, `02:46FF` | `0x0085A4`, `0x00863B`, `0x0086FF` | `CP $1E` (bound), set search value `$FF`, far-call `02:444D`, then **`JP C,$0965`** = bail if full. One of these is the shutter/capture path. |
| **"film full" refusal** | `02:45B6`, `02:464D`, `02:4711` | `0x0085B6`, `0x00864D`, `0x008711` | The `JP C,$0965` (`DA 65 09`) immediately after each scan. **This is the byte to neutralise.** |
| **Load dir SRAM→WRAM** | `02:4471` | `0x008471` | Copies `$B1B2`→`$D563` (30 bytes). |
| **Commit dir WRAM→SRAM + checksum** | `02:4407` / `02:43F9` | `0x008407` | Copies `$D563`→`$B1B2`, then writes checksum (see §3). |
| **Blank directory + checksum** | `02:4253` | `0x008253` | Writes `$FF`×30 at `$B1B2`, copies Magic from ROM `$4000`, writes checksum. (This is the retail "format/erase".) |
| **Checksum core** | `02:431F` | `0x00831F` | Computes 8-bit **sum→D** and 8-bit **xor→E** over a `BC`-length block at `HL`. |
| **Checksum store** | `02:432F` | `0x00832F` | Calls `431F`, then stores `D + $4E` and `E ^ $54` as the two checksum bytes. |

Far-call convention: caller does `LDH ($9E),A` (search value) → `LD A,<bank>` → `LD HL,<target>` →
`CALL $0956`. Dispatcher `$0956` saves the current bank, switches to the target bank, **restores `A`
from `$FF9E`**, then `JP HL`. Return trampoline is `$0965` (restores the saved bank).

---

## 2. The scan routine, annotated (`02:444D`)

```
444D  LD HL,$D563     ; WRAM working copy of the 30-byte directory
4450  LD B,$1E         ; 30 slots
4452  CP (HL)          ; A (= $FF when searching for a free slot) vs slot value
4453  JR Z,$445E       ; match -> found
4455  INC HL
4456  DEC B
4457  JR NZ,$4452      ; loop 30
4459  XOR A            ; not found: A = 0
445A  SCF              ; carry = 1  -> "FULL / not found"   <-- byte $00845A = 0x37
445B  JP $0965         ; far-return
445E  LD A,B           ; found: B = 30 - matched_index
445F  CPL
4460  ADD A,$1F        ; A = matched slot index (0-based)
4462  AND A            ; carry = 0 -> "found"
4463  JP $0965
```

`$444D` is **generic** ("find the slot whose value == A"): used for free-slot search (`A=$FF`) **and**
for locating a photo by image number (`A=0..29`). So patching its not-found branch directly would
break the photo-by-number lookups → **do not patch `$444D`**; patch the capture *site* instead.

## 3. Checksum algorithm (must stay correct or the save self-wipes)

```
431F: D=0, E=0; for each of BC bytes at HL:  D += byte ; E ^= byte ; HL++
432F: stored_sum = D + $4E ;  stored_xor = E ^ $54
```
The camera recomputes and writes these on every directory commit (`02:4407`) through its **own** code
path. Because our patch lets the *camera* write the photo + update the directory normally, the
checksum is recomputed by the ROM itself — **no manual checksum work, no suicide-wipe**, as long as we
do not alter the write/commit flow (only the full-refusal branch).

---

## 4. The grail patch (cyclic overwrite, ROM overlay in the core)

**Mechanism (doc 10 §7 step 2):** the core already reads physical ROM in passthrough and snoops bank
writes (`2000–3FFF`). Overlay = "when the gb reads ROM bank `$02` at this offset, return our byte
instead of the physical one." Track the bank, match `(bank=$02, offset)`, substitute.

**Option A — simplest, "overwrite slot 0 forever" (3 bytes):**
At the capture site's refusal, replace `JP C,$0965` (`DA 65 09`) with `NOP NOP NOP` (`00 00 00`).
When full, `$444D` already returns `A=0`, so execution falls through and the camera writes the new
photo into **slot 0**, overwriting it. Never refuses. *Limitation:* only slot 0 recycles; slots 1–29
keep their last photos until you shoot before filling.

**Option B — true `0→29` cycle (the real infinite roll, a few more bytes):**
Replace the refusal with a jump to a tiny injected routine (placed in spare ROM space, overlaid by the
core) that keeps a cycle counter in WRAM, computes `slot = counter; counter = (counter+1) mod 30`,
sets `A=slot`, and jumps back to the capture continuation (`$45B9`/`$4650`/`$4714` depending on the
site). This pairs perfectly with the savestate dump every 30: shoot → dump → keep shooting, photos
cycling `0..29..0`.

**Open item before coding:** confirm **which of the three sites** (`02:45A4` / `02:463B` / `02:46FF`)
is the shutter/capture path (the other two are likely "is there room?" / a secondary write). Quick
test: shoot on the real camera and see which site's offset the gb fetches (core log / bridge probe),
or single-step in an emulator (BGB) with a breakpoint at `02:444D` while taking a photo.

---

## 5. How to reproduce / continue the RE

- Scanner + mini-disassembler: `pocketroll/tools/gbcam-romscan.py` (committed).
  `python3 gbcam-romscan.py <rom.gb>` lists every imm16 reference to the directory/checksum addresses
  and every `LD HL,$B1B2`; the `dis(rom, foff, n)` helper dumps a disassembly window (import it).
- For a full, labelled disassembly, run the retail ROM through **mgbdis** (mattcurrie) → RGBDS asm,
  then jump to bank `$02` `$444D` and the three `$45A4/$463B/$46FF` sites.
- Behavioural model (not for offsets): `untoxa/gb-photo` `state_gallery.c` / `load_save.c`.

**Key facts that made it findable:** directory at CPU `$B1B2`; scan compares to `$FF`; counter `$1E`
(30); checksum seeds materialise as `+$4E` / `^$54` in the store routine; everything in bank `$02`,
identical US/JP.
