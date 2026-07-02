# PocketRoll — savestate RESUME glitch: handoff brief

*Self-contained onboarding for a fresh conversation dedicated to the ONE remaining problem: the gb
**glitches/freezes when a savestate resumes** (the save data is fine; only the resume is broken). Read
this + doc 09 (fluid savestate) + doc 11 (ROM patch). Everything else in the dream is done and validated.*

---

## 0. TL;DR

The infinite-roll dream is **functionally complete**: shoot forever (ROM overlay, behind a core-menu
toggle), savestate → a **valid `.sta`** lands on SD, MugDump (web v0.8) reads `.sta` → PNG. **The only
wart:** triggering a savestate (Analogue+Up) makes the Game Boy screen **glitch, resume ~1 ms, "split in
two", then freeze** — you must relaunch the core to continue. **The `.sta` is already written and valid
before the freeze**, so the dump works; it's the *resume* of the emulated gb that's broken. Goal of the
next session: make the savestate resume cleanly (no glitch/freeze) so batches chain without a relaunch.

**Crucial clue:** the glitch happens with the PocketRoll overlay **OFF** (toggle unchecked = the core is
byte-for-byte the stock budude2 core). So it is **NOT** our ROM patch. It is the savestate resume itself.

---

## 0.5 RESOLUTION (2026-07-02) — physical-cart PHI desync on resume ✅ CONFIRMED ON HARDWARE

**✅ FIXED & CONFIRMED on the Pocket (2026-07-02, commit `8405b51`).** Guillain built (Quartus 25.1),
flashed and tested: savestate now resumes cleanly — no split, no freeze, keeps shooting with no relaunch.
The "first brick" (fully autonomous infinite roll, end to end, zero PC in the field) is **closed**.

**Root cause (found by code analysis, confirmed by the fix working).** In physical passthrough the gb
CPU is *not* wait-stalled by the cart (`cart_wait_n = 1'b1`, core_top ~L987); a cart read is correctly
timed only because two clk_sys counters stay in phase: `clkdiv` (the `ce_cpu` phase generator inside
`speedcontrol`) and `cart_phi_counter` (the physical-cart PHI, core_top ~L1176). During a savestate the
gb is paused — `speedcontrol` freezes `clkdiv` — but **`cart_phi` kept free-running** through the (long)
state read-out. On resume `clkdiv` restarts at its frozen phase while `cart_phi` is at an arbitrary phase
→ the first cart read latches out-of-phase data → the CPU jumps to garbage and freezes; because it stops
writing LCDC/scroll mid-frame, the camera's raster UI "splits in two". This matches every symptom, is
independent of our overlay (both counters are stock), and explains why §3 was probably "always glitched":
the PHI-freeze never existed upstream (budude2's savestate targets SDRAM ROMs, not a live physical cart).
Confirms hypothesis #2; refutes #1 (the PPU savestate in `src/gb/video.v` is in fact complete — it
serialises the whole mid-frame pipeline: `h_cnt/v_cnt/pcnt/window_match/win_line/bg_fetch_cycle/…`).

**Fix (commit — this session).** Freeze `cart_phi` on exactly the cycles `clkdiv` is frozen, so the two
resume in-phase:
- `src/gb/speedcontrol.vhd`: new output `pause_active` = `'1'` while `state = PAUSED` (covers the entry at
  `clkdiv="111"` through the 15-cycle unpause tail — the full clkdiv-frozen window).
- `src/core/core_top.sv`: wire `cart_pause_active`; in the `cart_phi` counter, `else if (cart_pause_active)`
  holds `cart_phi_counter`/`cart_phi` (added before the `cart_phi_rise` branch). Residual phase skew ≈ 1
  clk_sys out of 32 (~3 %), well inside the ~24-cycle PHI-high data window.

**Why it's sufficient (no other desync source).** `speedcontrol` only enters PAUSED when `cart_act='0'`
(L62) → the gb never freezes mid cart-transaction; on resume it starts a fresh, correctly-timed cycle.
During pause `ce_cpu`/`ce_cpu2x` are gated, the CRAM snoop (L685) is gated by `ce_cpu`, `gb_cart_addr` is
held, and SDRAM refresh is internal (no PHI dependency). `cart_phi` was the only physical signal drifting.

**Status: ✅ DONE — built, flashed, confirmed clean on hardware (2026-07-02).** Savestate resumes with no
glitch/split/freeze; shooting continues without a relaunch. The "first brick" is closed. See §7.

---

## 1. What the glitch looks like (hardware, reported by Guillain)

- Trigger a savestate (Analogue + Up). The camera image glitches, comes back for ~1 millisecond, then
  **the screen splits in two** and everything freezes — no input works. Must quit/relaunch the core.
- "Split in two" strongly implies **PPU/LCD state corruption on resume** — specifically scroll (`SCX/SCY`),
  window (`WX/WY`), or `LYC`/`STAT` raster state restored wrong. The GB Camera UI uses mid-frame raster
  effects, so a savestate captured/restored at a bad scanline shows a split screen.

## 2. What is PROVEN (so we don't re-litigate)

- **The `.sta` write SUCCEEDS and is VALID.** Verified on a real capture
  (`…/Save States/Guillain-RDCDE.GBCAM/20260701_155523_…Play Cartridge.sta`, 234400 bytes):
  Magic echo/primary pair present → cart-RAM base `0xc57c`; directory `0x11B2 = 00 01 02 FF…` (3 photos);
  slots 0/1/2 hold real image data (479/894/2258 non-trivial bytes). MugDump decodes it fine.
- **The Pocket log confirms the save completes**: `State: Save → Query → prepare blob → Poll until done →
  State: Opening file […].sta → * complete`. (`<SD>/System/Logs/Guillain-RDCDE.GBCAM_*.txt`.)
- **It is not our overlay.** `git diff 0986332 HEAD -- src/core/core_top.sv` shows the overlay block is
  the only change since the last known-good-savestate commit; the overlay is gated behind
  `run_settings_s[8]` (core-menu toggle "PocketRoll: Infinite Roll", default OFF) AND gated off during
  `sleep_savestate`. With the toggle OFF, `cart_do` reverts to exactly the original expression
  (`cart_physical_mode ? cart_tran_bank1 : cart_do_backend`). The glitch still occurs → stock behaviour.
  Confirmed in the log: `Interact: saved ID [1007] … val 0x00000000` (toggle was OFF).
- **Not timing.** Latest build STA report: worst-case setup slack **+2.206 ns** (positive), hold +0.214.
- **Not album pollution.** Repro on a freshly-erased album with only 3 photos.

## 3. THE central open question (answer this FIRST next session)

**Did the savestate resume cleanly during the "fluid dump" era (~2026-06-25 to 06-27), or did it ALWAYS
glitch?** Doc 09 / memory claim the fluid savestate was "ZÉRO freeze, ZÉRO relaunch" — but that may have
been over-claimed, tested with very few photos (3), or at a lucky display moment.
- If it **used to resume cleanly** → a regression crept in (but the core_top diff says only the gated
  overlay changed; the always-active `gb_rom_bank` snoop is dead logic when the toggle is OFF — verify it
  can't perturb anything, e.g. re-synthesise without it to be 100% sure).
- If it **always glitched** → the fluid resume was never robust; the real task is to make the gb's
  savestate correctly capture/restore PPU/LCD state so the camera resumes.

Guillain has NOT yet definitively confirmed which. Establishing this is step 1.

## 4. Hypotheses to investigate (ranked)

1. **PPU/raster state not fully (or correctly) serialised/restored.** The "split screen" = scroll/window/
   LYC mismatch. Look at the gb core's savestate of the PPU (`src/gb/` — the savestate module,
   `Savestate*` signals, LCD/PPU regs). Does it save `SCX/SCY/WX/WY/LY/LYC/STAT/LCDC` and the mid-frame
   pipeline state? The GB Camera relies on precise raster timing.
2. **Resume re-enables the LCD / cart bus at a bad point.** In physical passthrough the cart bus is live;
   on resume, if the PPU restarts a frame mid-scanline while the physical cart drives data, the display
   desyncs. Interaction between `sleep_savestate` release and the physical-cart timing.
3. **The `cart_ram_size` force (=4/128 KB in physical mode, core_top ~L977) or `savestate_size`
   (L302 = 49968 + cart_ram_size_bytes)** makes the savestate blob larger; if some size/offset is off,
   restore could misalign a later state field (incl. PPU regs). Was the fluid dump validated on SAVE
   only, or also on a clean RESUME?
4. **The CRAM mirror path** (`pr_mirror_we`, cart.v) writes the internal CRAM during play; verify it
   doesn't corrupt a savestate region that overlaps PPU/OAM/HRAM state on resume.

## 5. Reference — the savestate machinery (core_top.sv)

- `save_state_controller` instantiated ~L823-861; `ss_save/ss_load`, `ss_din/ss_addr`, `ss_busy →
  sleep_savestate` (L861). `savestate_size` L302, `savestate_maxloadsize` L303.
- gb module wiring ~L1280-1310: `.save_state(ss_save)`, `.load_state(ss_load)`,
  `.sleep_savestate(sleep_savestate)`, `.SaveStateExt_*`, `.Savestate_CRAMAddr/RWrEn/WriteData/ReadData`,
  `.SAVE_out_Din/Dout/Adr/rnw/ena/be/done`.
- `cart_ram_size = cart_physical_mode ? 8'd4 : cart_ram_size_raw;` (L977) — the 128 KB force for the dump.
- Fluid-dump specifics are in **doc 09**; the mirror is in `src/gb/cart.v` (`pr_mirror_we`,
  `pr_phys_data`, `Savestate_CRAM*` gated by `sleep_savestate`).
- The gb core PPU/savestate lives under `src/gb/` (budude2 fork of the MiSTer Gameboy core; savestate
  framework = `SaveStateExt_*` / `SAVE_out_*`). That's where PPU-state (mis)restore likely is.

## 6. Reference — the ROM overlay (doc 11), now behind a toggle

All in ROM bank `$02`, offsets identical US "GAMEBOYCAMERA" & JP "POCKETCAMERA V1.1". Active only when
core-menu **"PocketRoll: Infinite Roll"** is ON (`run_settings_s[8]`; `interact.json` id 1007). Overlay =
snoop `gb_rom_bank` (writes to `$2000-$3FFF`) + substitute bytes on `cart_do` when the gb reads bank `$02`:
- (a) **count cap** — offset `$049B` `1E`→`1D`: the used-slot count loop (`02:4499`) counts 29 not 30, so
  `$D561` never reaches 30 and every "film full" gate (`($D561)>=30`, spread across banks 4/6/7 + the
  write-site preambles) passes.
- (b) **redirect** — offset `$0459-$045B` (`AF 37 C3`) → `C3 B5 7A` = `JP $7AB5`: reroutes `02:444D`'s
  not-found branch.
- (c) **injected routine** — offset `$3AB5-$3ACD` (`$7AB5`, free `$00` in both ROMs), 25 bytes
  `FE FF 20 0D 21 63 D5 AF 06 1E BE 28 09 23 05 20 F9 AF 37 C3 63 44 C3 5E 44` =
  `CP $FF; JR NZ,.nf; scan $D563 for value 0 (oldest); .f: JP $445E; .nf: XOR A;SCF;JP $4463`. Only a
  free-slot search (A=$FF) is diverted → returns the OLDEST photo's slot → cyclic 0→29 overwrite;
  by-number lookups keep stock "not found" (regressing them corrupts state → crash).
- Cause of "film full" = the photo count `$D561`, recomputed by `02:4466` (reload dir `$B1B2`→WRAM
  `$D563`, renumber/compact = the "sliding roll", then count non-`$FF`). `02:444D` = the shared free-slot
  scan. `02:431F`/`432F` = checksum (sum+`$4E`, xor^`$54`), recomputed by the ROM → no suicide-wipe.
- Scanner/mini-disassembler: `pocketroll/tools/gbcam-romscan.py` (`import scan; scan.dis(rom, foff, n)`).
- ROMs used for RE: `pocketroll/samples/emutest-original/gbcam.gb` (US) + a JP "Pocket Camera (J) V1.1".

## 7. State of the world (all validated on hardware unless noted)

- ✅ Infinite roll (cyclic overwrite) — proven; photos land in different slots (30,29,28…), MugDump shows
  new photos replacing old ones.
- ✅ Savestate WRITE → valid `.sta` with real photos.
- ✅ MugDump **web** reads `.sta` (v0.8.0; ported `coerceGbCamSave` to `docs/`; earlier only Electron had
  it). Repo `Guillain-RDCDE/MugDump`, branch `main`.
- ✅ **Savestate RESUME — FIXED & CONFIRMED on hardware (§0.5, commit `8405b51`).** The physical-cart PHI
  free-ran during the savestate pause and resumed out of phase; now `cart_phi` freezes in lockstep with the
  CPU clock. Tested on the Pocket: clean resume, no relaunch. The relaunch-per-batch wart is **gone**.

**🏆 The infinite-roll dream is now complete AND wart-free**: shoot → savestate (clean resume) → keep
shooting forever → dump `.sta` → MugDump → PNG, all on the Pocket + cartridge + SD, zero PC in the field.

Current usable workflow (with the wart): toggle ON → shoot 30 → toggle OFF → open photo 1 + L1
auto-browse → savestate (`.sta` saved) → **relaunch core** → toggle ON → shoot 30 → … ; MugDump at home.

## 8. Build / flash / test (unchanged)

- Quartus **25.1** (`` `define isgbc 0 `` in core_top.sv), Start Compilation → `src/output_files/ap_core.rbf`
  (check `ap_core.flow.rpt` "Flow Status: Successful").
- `node pocketroll/core/reverse_rbf.js src/output_files/ap_core.rbf bitstream.rbf_r`
- Copy `bitstream.rbf_r` → `<SD>\Cores\Guillain-RDCDE.GBCAM\gb.rbf_r` (SD = `E:`). If `interact.json`
  changed, copy it too: `pkg/gb/Cores/Guillain-RDCDE.GBCamera/interact.json` → same SD folder.
- Savestate trigger = **Analogue + Up**; lands in `<SD>\Memories\Save States\Guillain-RDCDE.GBCAM\*.sta`
  (~234 KB). Debug logs in `<SD>\System\Logs\`.
- Guillain compiles/flashes (assistant can't); assistant does the reverse+copy and reads SD/logs (E:).

## 9. Milestone commits (branch master)

Overlay journey: `a7ee612` RE/doc → `66e95dc` Phase-1 (3 write sites) → `fee9b29` count-gate cap +
444D→slot0 → `06e377a` Phase-2 cyclic (oldest) → `b1439fa`/`2bd36ae` savestate-crash fixes (by-number
restore + `~sleep_savestate` gate) → `a4554da` runtime toggle → `632c9eb` docs. MugDump: `2227a24` web
`.sta`, `c1d351b` renderer mirror, `41596a9` version bump 0.8.0. Docs 06-12.

## 10. Constraints / operating rules

- No JTAG, never open/buy the Pocket. Debug via Pocket Debug Logging (`/System/Logs/`) + reading the SD.
- Commit identity **Guillain-RDCDE**, zero Claude attribution, push direct to master/main, selective
  `git add`. Never commit personal photo files (`*.sav`/`*.sta`) or ROM `.gb` files. Respond in French.
- **First move next session: get Guillain to confirm §3** (did resume ever work cleanly?), then dig into
  the gb core's PPU savestate (§4/§5).
