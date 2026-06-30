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

---

## 6. The three sites are ALL photo-writes (refined finding)

Dumping the full bodies of `02:45A4 / 463B / 46FF` shows they are **three variants of "write a photo to
a free slot"**, not one capture + two unrelated ops. Each ends with the **identical tail**:

```
INC A ; LD ($4000),A          ; select the slot's SRAM ROM/RAM bank (slot+1)
LD HL,$A000 ; ADD HL,DE
LD DE,$C000 ; LD BC,$0FB8      ; copy 0x0FB8 (4024) bytes of image from WRAM $C000 ...
<copy loop>                    ; ... into the SRAM photo slot
POP HL ; LD A,($D561) ; LD (HL),A   ; write the directory entry
CALL $43F9                     ; commit dir $D563->$B1B2 + recompute checksum
... JP $4466                   ; reload dir, far-return
```

and the **identical preamble**: `CP $1E` (bound) → set `$FF` → far-call `02:444D` → `JP C,$0965`
(bail if full). They differ only in the metadata set up before the copy:
- **`02:45A4`** — simplest; sets `$CF33/$CF8F=1`, checksums `$CF00/$CF5C`, runs the directory
  **renumber** loop (`$460A`: increments image numbers ≥ the inserted one). **Most likely the plain
  shutter "take a photo".**
- **`02:463B`** — `B=2` loop, bumps `$CF12` counters capped at `$63` (99), reads `$DA56`.
- **`02:46FF`** — builds the image from a template (`$47B3`→`$CE00` via `$0462`/`$2685`/`$2A71`), uses
  `$DA49/$DA8F/$DA90`.

Because the *full-refusal* (`JP C,$0965`) and the *slot index in `A`* are common to all three, a patch
that neutralises the refusal makes **whichever site is the shutter** stop refusing — no need to
pre-identify it.

> ROM version note: the refusal opcode bytes differ only in the **return address** — US `DA 65 09`
> (`JP C,$0965`), JP V1.1 `DA D0 08` (`JP C,$08D0`) — but the **bank-`$02` offsets are identical**
> (`$05B6 / $064D / $0711`). Neutralising to `00 00 00` is therefore version-agnostic.

---

## 7. Implementation plan (build-ready)

The core already does passthrough ROM reads + bank snoop. The **ROM-overlay** = "when the gb reads ROM
bank `$02` at offset X (in the `$4000–$7FFF` window), return our byte instead of the physical one."
Spare overlay canvas confirmed: **bank `$02`, CPU `$79D2–$7FFF` (1582 bytes of `$00`)**,
foff `0x00B9D2` — free to host an injected routine.

### Phase 1 — "never refuse" (surgical, version-agnostic, ~9 overlay bytes) → FIRST hardware test

Force `$00` at the three refusal sites (turns each `JP C,…` into `NOP NOP NOP`). When full, `02:444D`
already returns `A=0`, so the camera writes the new photo into **slot 0** instead of refusing.

| Site | bank `$02` offset | foff | physical bytes | overlay → |
|---|---|---|---|---|
| 45A4 | `$05B6` | `0x0085B6` | `DA 65 09` (US) / `DA D0 08` (JP) | `00 00 00` |
| 463B | `$064D` | `0x00864D` | idem | `00 00 00` |
| 46FF | `$0711` | `0x008711` | idem | `00 00 00` |

This is safe (leaves `02:444D`'s by-image-number lookups untouched) and proves the whole overlay
mechanism on hardware. **Limitation:** only slot 0 recycles, so shots >30 overwrite slot 0 each time —
good enough to validate, not the final infinite roll. It also reveals which site is the shutter and how
the renumber loop behaves when reusing an occupied slot.

### Phase 2 — true cyclic roll (the grail; pairs with savestate-dump-every-30)

Redirect each refusal to an injected routine in the spare canvas:
`JP C,$0965`(`DA 65 09`) → `JP C,$79D2` (`DA D2 79`). At `$79D2`, the injected routine picks a cycling
target slot (round-robin counter in a free HRAM/WRAM byte, **or** the oldest slot = lowest directory
value, which is stateless), sets `A`, then jumps back into that site's continuation
(`$45B9 / $4650 / $4714`). With cycling overwrite, after each batch of 30 you savestate-dump and keep
shooting — **this eliminates the film-reset problem entirely** (no blanking needed).

**Open items before/at Phase 2 build (validate in BGB on the retail ROM first):**
1. Which site is the shutter (so the jump-back targets the right continuation) — Phase 1 answers this.
2. Slot-selection strategy + interaction with the renumber loop (`$460A`): round-robin counter vs
   overwrite-oldest. Confirm the directory + checksum stay self-consistent (the ROM's own `$43F9`
   commit recomputes the checksum, so the suicide-wipe is avoided as long as we only change the slot
   index, not the write/commit flow).

### FPGA overlay sketch (`core_top.sv` / `cart.v`)

Track the current ROM bank (snoop writes to `$2000–$3FFF`, as we already do for RAM banks). On a
physical ROM read in the `$4000–$7FFF` window, if `rom_bank == 8'h02` and the in-bank offset matches a
patch entry, drive the patched byte onto `cart_do` instead of `cart_tran_bank1`:

```verilog
// pseudo: rom_bank latched from 2000-3FFF writes; addr = gb cart address
wire in_hi   = (addr[15:14] == 2'b01);            // $4000-$7FFF
wire [13:0] off = addr[13:0];                      // offset within the banked window
wire patch_hit = cart_physical_mode & in_hi & (rom_bank == 8'h02) &
                 ( (off==14'h05B6)||(off==14'h05B7)||(off==14'h05B8)    // site 45A4 refusal
                 ||(off==14'h064D)||(off==14'h064E)||(off==14'h064F)    // site 463B refusal
                 ||(off==14'h0711)||(off==14'h0712)||(off==14'h0713) ); // site 46FF refusal
wire [7:0] patch_byte = 8'h00;                      // Phase 1: NOP
assign cart_do = (patch_hit) ? patch_byte
               : cart_physical_mode ? cart_tran_bank1 : cart_do_backend;
```

Phase 2 extends `patch_hit` with the `$79D2…` injected-routine bytes and changes the three refusal
overlays from `00 00 00` to `DA D2 79`. **Untested scaffold — build in Quartus 25.1 (`isgbc 0`) and
verify on hardware per the project's flow.**

---

## 8. Hardware test #1 result → patch moved to the shared scan `02:444D` (2026-06-29)

**Phase-1 (the three write-site refusals) did NOT work**: at 30 photos the camera shows **"no blank
frame"** and blocks the shutter. Diagnosis: the three sites `45A4/463B/46FF` are the *photo-write*
routines, reached **after** a *separate "is there a blank frame?" gate* has already passed. The gate
runs first and shows "no blank frame", so the write sites are never reached — neutralising their
`JP C` is moot.

**Root-cause fix — patch the shared chokepoint instead.** Every free-slot question (the gate *and* the
write sites) far-calls **`02:444D`**, the one scan that returns carry=SET when the directory is full.
`02:444D` is generic (also used for by-image-number lookups — e.g. the home-bank caller `00:1702` does
`BIT 7,A` then far-calls it with an image number), so we can't blindly force slot 0 for *found* — but
we can make **"not found" return slot 0**:

- Overlay `02:444D`'s not-found branch, bank-`$02` offset **`$0459`–`$045D`** (physical
  `AF 37 C3 65 09` = `XOR A; SCF; JP $0965`) → **`06 1E C3 5E 44`** = `LD B,$1E; JP $445E`.
- This jumps into `444D`'s own **found-branch** (`$445E`), which computes `A = 0` with **carry clear**
  and returns via the ROM's existing `JP` (US `$0965` / JP V1.1 `$08D0`) → **version-agnostic** (we
  reuse whichever return the cart has; we never encode it).
- Net: `02:444D` now *always* reports a slot — the real one when present, else **slot 0**. The gate
  sees "blank frame available", the shutter is allowed, and capture writes to slot 0.

Side effect (acceptable): a by-image-number lookup that genuinely misses now returns slot 0 instead of
"not found". In normal use those lookups target existing photos, so they hit the unchanged found-branch;
the miss case is rare and low-risk for the experiment.

This is the current overlay in `core_top.sv` (replaces the three-site `00 00 00`). Single 5-byte patch
at one offset, version-agnostic. **If "no blank frame" still appears after this build**, the gate uses
an *inline* `$D563` scan (not `444D`) and we locate that next; but `444D` is the natural shared chokepoint.
Phase 2 (true `0→29` cycle via the `$79D2` injected routine) still applies on top once capture is confirmed.

---

## 9. Hardware test #2 result → the gate is a COUNT, not a scan (2026-06-30)

**The `02:444D` patch alone did NOT lift the limit either** — still "no blank frame" at photo 31,
*identical* behaviour (so the gate never consulted the patched branch). User clue: deleting photo 1
makes photo 2 become photo 1 — the directory **slides/renumbers**. That pointed at a maintained
**count**, not a per-shutter free-slot scan.

Found it. `02:4466` runs after every photo operation and does three things:
1. reload directory `$B1B2`→`$D563`;
2. **renumber/compact** the display numbers contiguously (`$447F–$4497`) — this is the "sliding";
3. **count used slots** (`$4499`: `LD BC,$1E00`; loop 30× `LD A,(HL+); CP $FF; INC C if used`) and
   store the count at **`$D561`** (`$44A9`, the *only* writer of `$D561`).

Every "film full" gate across the ROM is then `LD A,($D561); CP $1E; …NC→full` (e.g. bank 4 `$4E87`,
bank 6 `$504B/$52AD/$6070`, bank 7 `$411C`, and the write-site preambles). The shooting-mode shutter
gate is one of these — independent of `02:444D`, which is why both earlier patches missed it.

**Single-point fix: stop the count from reaching 30.** Cap the count loop to 29 slots —
bank-`$02` offset **`$049B`** (`02:4499`'s `LD BC,$1E00`, the high byte `$1E`) → **`$1D`**. Then
`$D561` maxes at 29 and **every** gate passes. When the camera then actually allocates a slot it still
needs a physical free one, so we keep patch (b) `02:444D`→slot 0. Together: count gate always passes →
shutter allowed → `444D` yields slot 0 when full → photo overwrites slot 0. Both patches are in
`core_top.sv` (offsets `$049B` and `$0459–$045D`), version-agnostic.

> Why capping at 29 is safe: photos fill lowest-slot-first, so physical slots `0–28` are all occupied
> exactly when the roll is full — the loop (now slots `0–28`) reads 29, never 30. Other `$D561`
> consumers (e.g. "≥10 photos" minigame checks) only care about lower thresholds, unaffected.

Still Phase-1 semantics (overwrite slot 0). Once this confirms "never refuses + writes", Phase 2 swaps
patch (b) for the cycling routine for a true `0→29` roll.

---

## 10. Hardware test #3 → IT WORKS, infinite shooting → Phase 2 (cyclic) (2026-06-30)

**Test #3 succeeded**: shot ~37 photos into an empty album with no "no blank frame" — the count cap +
`02:444D`→slot-0 defeated the gate and the camera kept capturing. Observed: the counter went to 1 at
photo 30 and stayed at 1; the film held photos ~2–29, slot 30 empty, slot 1 = the *latest* shot. That
is exactly Phase-1 (overwrite one slot): the count is capped at 29 (so slot 30 reads "uncounted" and the
displayed counter can't pass) and `02:444D` returns the lowest slot (0) every time it's full, so every
shot past the fill overwrites that one slot.

**Phase 2 — true `0→29` ring (current overlay).** Replace patch (b): instead of always returning slot 0,
redirect `02:444D`'s not-found branch to an injected routine that returns the **oldest** photo's slot
(directory display-number `0`). Because `02:4466` renumbers/compacts after every shot, "number 0"
rotates across physical slots, so successive full writes recycle slots oldest-first = a real ring. The
dump (savestate) then reads 30 distinct recent photos; shoot 30 → dump → shoot 30 (overwriting the
oldest) → dump → … infinite, **no reset needed**.

Overlays now (all bank `$02`, free space common to US & JP):
- (a) count cap — offset `$049B` `1E`→`1D` (unchanged).
- (b) redirect — offset `$0459`–`$045B` (`AF 37 C3`) → `C3 B5 7A` = `JP $7AB5`.
- (c) injected routine — offset `$3AB5`–`$3AC4` (`$7AB5`, `$00` in both ROMs) →
  `21 63 D5 AF 06 1E BE 28 04 23 05 20 F9 C3 5E 44` =
  `LD HL,$D563; XOR A; LD B,$1E; .l: CP (HL); JR Z,.f; INC HL; DEC B; JR NZ,.l; .f: JP $445E`
  (falls into `444D`'s found-branch → returns the oldest slot index, carry clear, version-agnostic).

Implemented in `core_top.sv`. **UNTESTED — rebuild Quartus 25.1.** Expected: shooting past 30 overwrites
slots in oldest-first order (the gallery's oldest photo is the one replaced), not always slot 1.
