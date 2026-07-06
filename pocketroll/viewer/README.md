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
| [`rtl/video_gen.v`](rtl/video_gen.v) | raster the framebuffer → openFPGA video (rgb/de/hs/vs), 2bpp→palette | ✅ simulated |
| [`rtl/framebuffer.v`](rtl/framebuffer.v) | 14336×2 dual-port store (decode writes, video reads) | ✅ elaborated |
| [`rtl/viewer_top.sv`](rtl/viewer_top.sv) | logic core: load → locate → summary → decode → video, D-pad nav | ⚙️ elaboration-checked skeleton |
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
4. `video_gen` is checked pixel-by-pixel over two frames against an independent
   reference raster (sync timing, active-window count, image placement, 2bpp→palette
   mapping, blanking). `viewer_top` (the whole pipeline wired together) elaborates.

Run it:
```sh
bash sim/run.sh      # needs node + iverilog (scoop) on PATH
# => *** MODEL PASS ***  /  *** PHOTO_DECODE PASS ***  /  *** STA_LOCATE PASS ***
```

## Not here yet (hardware phase, Guillain's build loop)

- `core_top.sv` — a budude2-derived APF wrapper with the Game Boy removed, that (a) has
  the host load the picked `.sta` into a buffer via an APF dataslot, (b) drives the PLLs
  and the pixel clock, (c) edge-detects the D-pad into `key_next`/`key_prev`, and (d)
  instantiates **`viewer_top`** and routes its `video_*` to the Pocket outputs. The logic
  pipeline (`viewer_top`) is already written and wired; this is the APF/clock/input glue
  (Option A in doc 13 §6: reuse budude2's proven plumbing).
- `pkg/.../{core.json,data.json,video.json}` — one user-selectable savestate slot + the
  video mode matching `video_gen`'s H/V totals.
- **Real memory latency:** the unit sims use an async read; on a registered BRAM/SDRAM,
  add one wait cycle in the read states of `photo_decode`/`sta_locate` and one pipeline
  stage in `video_gen` (the FSMs are staged to slot it in).

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
