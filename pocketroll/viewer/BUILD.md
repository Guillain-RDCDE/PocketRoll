# Viewer — build (iteration 2: decode from cram, no 128 KB buffer)

The photo viewer is grafted into the **existing PocketRoll core** as an optional mode — you
compile the normal project (`src/`), same `ap_core.qpf`. Everything is gated behind a
core-menu toggle, so with it **off** the core behaves exactly as before.

> **First build (iter 1) failed on M10K overflow** — the 128 KB on-chip file buffer didn't
> fit (exactly the risk flagged). **Fix (iter 2, this commit):** drop the buffer entirely and
> **decode straight from the GB core's existing 128 KB cart RAM (`cram`)** — the memory that
> already holds the camera's photos — via a read port added on cram's port B (used only while
> viewing, when the save-backup path is idle). **No memory added** beyond the tiny 3.5 KB
> framebuffer, so it should now fit.
>
> ⚠️ Still **not hardware-tested** — the logic elaborates and reuses simulation-verified
> modules, but this is the build loop: compile → tell me the Fitter result / what's on screen
> → I fix → repeat.

## What was changed (committed)

- **`src/gb/cart.v`** — a `viewer_en` + `viewer_rd_addr`/`viewer_rd_data` byte-read port that
  reuses cram's port B (muxed so writes/saves are never disturbed).
- **`src/core/core_top.sv`** — gated by `run_settings_s[9]`: D-pad edge-detect, a
  `viewer_overlay` instance reading cram, a `viewer_refresh` on enable, and the video mux
  `video_rgb_reg <= (viewer_en && ov_active) ? ov_rgb : video_rgb_gb;`. Cart instance wired to
  the new port.
- **`pocketroll/viewer/rtl/viewer_overlay.sv`** — no internal buffer now; decodes cram into a
  14336×2 framebuffer and outputs the overlay pixel. `.qsf` lists it + `gbcam_photo_decode.v`.
- **packaging** — the "PocketRoll: Viewer" toggle (interact id 1008, bit 9). *(The id-30 data
  slot from iter 1 is now unused — harmless; the viewer reads cram, not a loaded file.)*

## Build & flash (same as PocketRoll)

1. Quartus **Prime Lite 25.1**, `` `define isgbc 0 ``, Start Compilation.
2. **Check the Fitter first** — does it fit now? (That was the iter-1 blocker.)
3. `node pocketroll/core/reverse_rbf.js src/output_files/ap_core.rbf bitstream.rbf_r` → I do this
   + the SD copy; send me the `.rbf`.
4. Copy the updated `interact.json` to `<SD>\Cores\Guillain-RDCDE.GBCAM\` too.

## Use it

1. Launch with the GB Camera cartridge as usual and take some photos (they live in cart RAM).
   *(Or load a saved roll: put a `.sav` in the normal **Save** slot — it lands in cram too.)*
2. Core Settings → tick **PocketRoll: Viewer**.
3. The current photo appears centred; **D-pad ◀ ▶** steps through the 30 slots.

## Check at this build

1. **Fit** — should pass now (no 128 KB buffer). If it still overflows, tell me by how much.
2. **cram port-B sharing** — the viewer read is muxed onto port B (save I/O assumed idle while
   viewing). If the picture is garbage, this mux or the byte-select is the suspect.
3. **Framebuffer clk_sys→clk_ram crossing** + the ~1 px overlay offset — cosmetic; nudge `IMG_X`.
4. **What decodes** — cram holds whatever the cartridge currently has; empty slots → lightest
   shade. If nothing overlays at all, check `viewer_en`/`h_cnt`/`v_cnt` reach the module.

If it fits and boots showing *something* centred that changes with the D-pad, the video +
decode + cram path are proven and we polish from there.
