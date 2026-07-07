# Viewer — first build

The photo viewer is grafted into the **existing PocketRoll core** as an optional mode, so
you compile the normal project (`src/`) — no separate Quartus project. Everything is gated
behind a core-menu toggle, so with it **off** the core behaves exactly as before.

> ⚠️ **This is the FIRST build of the hardware integration.** The logic modules are
> simulation-verified, but the wiring into budude2's APF/video (the parts I can't compile or
> flash) has **not** been hardware-tested. Expect to iterate: compile, send me the Quartus
> log / what you see on screen, I fix, repeat — same loop as PocketRoll itself.

## What was changed (already committed)

- **`src/core/core_top.sv`** — added, all gated by `run_settings_s[9]`:
  - a `viewer_download` decode for dataslot **id 30** (in the download `case`);
  - D-pad edge-detect (`cont1_key_s[3]`=next, `[2]`=prev) + a `viewer_load_done` pulse;
  - a `viewer_overlay` instance (clk_sys + clk_ram, fed by `ioctl_*`, `h_cnt`/`v_cnt`);
  - the video mux: `video_rgb_reg <= (viewer_en && ov_active) ? ov_rgb : video_rgb_gb;`.
- **`src/ap_core.qsf`** — added `pocketroll/viewer/rtl/gbcam_photo_decode.v` + `viewer_overlay.sv`.
- **`pkg/gb/Cores/Guillain-RDCDE.GBCamera/{data.json,interact.json}`** — a "Viewer Save"
  slot (id 30, `.sav`, `0x10000000`) and a "PocketRoll: Viewer" toggle (id 1008, bit 9).

## Build & flash (same recipe as PocketRoll)

1. Quartus **Prime Lite 25.1**, `` `define isgbc 0 `` in `core_top.sv`, Start Compilation.
2. **Read the Fitter report first** — see risk #1 below (does it fit?).
3. `node pocketroll/core/reverse_rbf.js src/output_files/ap_core.rbf bitstream.rbf_r`
   (I do this step + the SD copy — send me the `.rbf`).
4. Copy `bitstream.rbf_r` → `<SD>\Cores\Guillain-RDCDE.GBCAM\gb.rbf_r`, **and** copy the updated
   `interact.json` + `data.json` to that same SD folder.

## Use it

1. Launch the core with a ROM as usual (the core still needs a cartridge/BIOS to boot).
2. Core Settings → tick **PocketRoll: Viewer**.
3. Load a **128 KB `.sav`** into the **Viewer Save** slot (MugDump can export a `.sav` from
   any `.sta` — v1 takes `.sav`, not `.sta` directly; see risk #6).
4. The photo appears centred on screen; **D-pad ◀ ▶** steps through the 30 slots.

## Known unknowns — check these at the first build (honest list)

1. **BRAM fit (most likely issue).** The viewer adds a 128 KB file BRAM + a 14336×2
   framebuffer on top of the full GB/SGB core. The Pocket's Cyclone V may not have room.
   → If the Fitter fails on memory, tell me; options: shrink the buffer, drop SGB, or move
   the file buffer to SDRAM (reuse the cart download path instead of an on-chip BRAM).
2. **Slot load path.** The Viewer slot sits at `0x10000000` (the `data_loader`/`ioctl`
   region) and is distinguished by id 30 → `viewer_download`. If the file doesn't reach the
   BRAM (blank screen even with a valid `.sav`), the slot address/region or the ioctl gating
   needs adjusting.
3. **Video timing / 1-px offset.** The overlay reuses budude2's `h_cnt`/`v_cnt` (clk_ram) and
   the sync framebuffer read adds ~1 pixel of latency → a possible 1-px horizontal shift.
   Cosmetic; nudge `IMG_X` in `viewer_overlay.sv` if needed.
4. **Dual-clock framebuffer.** Written on `clk_sys` (decode), read on `clk_ram` (pixel).
   Quartus should infer a dual-clock BRAM; watch for timing warnings.
5. **`clk_ram` vs `clk_vid`.** `h_cnt`/`v_cnt` come from the `video` module clocked on
   `clk_ram`, so the overlay's pixel side is on `clk_ram`; the output regs are on `clk_vid`
   (same as the stock path). Verify this holds.
6. **`.sav` only (v1).** 128 KB cart RAM, base 0, no Magic scan. `.sta` (~234 KB) support =
   a bigger buffer + the already-tested `gbcam_sta_locate` scan — the next iteration.

Milestone 1 (doc 13 §7) is "boots + shows a photo". If the first build fits and boots, we're
most of the way there; the rest is nudging offsets and the load path.
