# On-board viewer — scaffold

The decode heart of the on-board photo-viewer core (design: [`../docs/13-onboard-viewer-core-design.md`](../docs/13-onboard-viewer-core-design.md)).
This is the part that can be **written and verified in simulation today**; the rest
(APF wrapper, video output, PLLs, packaging) is hardware integration that needs the
Quartus → reverse → flash loop and can only be validated on a real Analogue Pocket.

## What's here (tested)

| File | What | Status |
|---|---|---|
| [`rtl/gbcam_photo_decode.v`](rtl/gbcam_photo_decode.v) | decode one photo slot → 128×112 2bpp framebuffer | ✅ simulated |
| [`rtl/gbcam_sta_locate.v`](rtl/gbcam_sta_locate.v) | find the cart-RAM base inside a `.sta` (Magic-pair scan) | ✅ simulated |
| [`sim/viewer_model.js`](sim/viewer_model.js) | reference model + test-vector generator | ✅ |
| `sim/tb_*.v` | Icarus testbenches | ✅ |

**How it's verified**
1. `viewer_model.js` decodes a **real `.sta`** and checks our decode against MugDump's
   `gbcam.js` **pixel-for-pixel** (skipped automatically when the local files aren't
   present — no personal data is committed).
2. It then builds a **synthetic, deterministic** cart RAM + `.sta` and emits
   `$readmemh` vectors + the expected framebuffer.
3. The testbenches run the Verilog against those vectors: `gbcam_photo_decode`
   reproduces the framebuffer byte-for-byte; `gbcam_sta_locate` finds the right base
   for both a `.sta` (base `0x466C`) and a raw 128 KB `.sav` (base `0`).

Run it:
```sh
bash sim/run.sh      # needs node + iverilog (scoop) on PATH
# => *** MODEL PASS ***  /  *** PHOTO_DECODE PASS ***  /  *** STA_LOCATE PASS ***
```

## Not here yet (hardware phase, Guillain's build loop)

- `video_gen.v` — raster over the framebuffer: openFPGA video (`video_rgb/de/hs/vs`),
  integer-scale + centre the 128×112 image, 2bpp → palette, `photo N/M` overlay.
- `core_top.sv` — a budude2-derived APF wrapper with the Game Boy removed, wiring
  **dataslot load → `sta_locate` → `photo_decode` → framebuffer → `video_gen`**, plus
  D-pad ◀ ▶ to change photo. (Option A in doc 13 §6: reuse budude2's proven APF/video/
  PLL plumbing.)
- `pkg/.../{core.json,data.json,video.json}` — one user-selectable savestate slot.

## Notes for the hardware wiring

- The RTL reads the buffer over a simple byte port (`mem_addr`/`mem_data`). The
  testbench uses a **combinational** read; on real BRAM/SDRAM (registered, 1-cycle
  latency) the read states need one extra wait cycle — the FSMs already have the
  `S_RDLOW`/`S_RD` staging to slot that in.
- Framebuffer = 14 336 × 2 bits (3.5 KB) — trivial dual-port BRAM (decode writes, the
  raster reads).
- `photo_decode` addressing and `sta_locate`'s Magic scan mirror `coerceGbCamSave` +
  `decodePhoto` in [MugDump `gbcam.js`](https://github.com/Guillain-RDCDE/MugDump/blob/main/docs/js/gbcam.js),
  so the on-device image is identical to what MugDump develops.

Milestones are in doc 13 §7.
