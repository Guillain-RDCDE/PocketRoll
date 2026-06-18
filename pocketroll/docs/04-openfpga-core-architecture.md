# Step 3/4 — openFPGA core architecture (recon)

> Before installing Quartus and suffering, we map the terrain: does
> [budude2](https://github.com/budude2/openfpga-GBC)'s Game Boy core (the one that already runs the
> physical cartridge) contain what we need, and **where** do we graft our two add-ons (sensor + SD
> export)?

---

## 🟢 In plain English

Good news: we're not starting from a blank page. The open-source Game Boy core for the Pocket
**already** knows how to (a) run a physical Game Boy cartridge, (b) recognize the *type* "Game Boy
Camera," and (c) **save the cartridge memory to a file on the SD card**.

What's missing is exactly the two pieces PocketRoll needs:
1. **the photo sensor** — the core recognizes the camera but can't read its images (it returns
   black); we need to pass the real sensor data through from the cartridge;
2. **infinite export** — the SD save exists, but capped at the cartridge size (128 KB, ~30 photos).
   To go beyond, we recycle slots (our validated recipe) or push each photo to its own file.

## 🔴 The exact graft points

### 1. The sensor — **probably already handled by physical mode** 🎉

First read: the internal `gb_camera.v` mapper **stubs out the sensor**
(`cram_do = cam_en ? 8'h00 : cram_di` → CAM reads = `0x00`). BUT that mapper is in the **emulated
backend**, and the analysis of `core_top.sv` shows that in **physical cartridge mode** this backend
is **disabled**:

```verilog
wire backend_cart_rd = ~cart_physical_mode & cart_rd;          // backend OFF in physical mode
assign cart_do = cart_physical_mode ? cart_tran_bank1 : cart_do_backend;  // data = REAL cartridge
assign cart_tran_bank0 = cart_physical_mode ? {cart_phi, …} : …;          // + real PHI clock
```

In physical mode, the core **passes the whole Game Boy bus through live** to the cartridge pins:
address, bidirectional data, control **and the PHI clock**. So **the real cartridge's ROM, RAM and
M64282FP sensor are all live** — the `0x00` stub does not apply. The "sensor passthrough" I thought
was the big Verilog chunk is, in all likelihood, **already done by budude2's physical mode**.

> [Issue #4](https://github.com/budude2/openfpga-GBC/issues/4) is an **old request** predating
> physical-cartridge support (v1.4.0); it doesn't prove the camera fails. **Nobody had tested it.**
> Hence the decisive test below.

#### ✅ Hardware test — CONFIRMED (2026-06-17)

Real Game Boy Camera cartridge in the Pocket + budude2's **GB core** in external-cartridge mode +
taking a photo → **the image is captured and saved.** The sensor passthrough **works**. **The
project's #1 risk ("get the sensor through") is gone — without a line of Verilog.**

Consequence: only **one** real piece of work remains → the **export + recycling automation** (below),
entirely built on our already-validated SRAM recipe.

### 2. SD export — `data.json` + `src/gb/data_unloader.sv`

The save slot already exists:

```json
{ "name": "Save", "id": 18, "nonvolatile": true,
  "extensions": ["sav","srm"], "address": "0x20000000", "size_maximum": "0x20050" }
```

APF automatically persists this region (the cartridge SRAM) into the SD's `.sav` via
`data_unloader.sv`. **But `size_maximum` = `0x20050`** (128 KB) → no growing album here. Two
strategies for infinity:

- **Recycle + host pickup**: after each shot, apply our recipe (`0xFF` + checksum + echo, see
  [Step 1/2](01-game-boy-camera-sram-format.md)) to free a slot; the full album is reconstituted on
  the PC side ([MugDump](../../MugDump)) from the successive `.sav` files. Simplest.
- **Per-photo export**: a custom APF slot/push (`data_unloader`) that writes each finished image to
  its own SD file. Cleaner ("one file per photo, forever"), more plumbing.

### 3. The glue

`src/core/core_top.sv` (the core's top level) and `src/gb/cart.v` (cartridge interface) are where the
"photo finished" detection, the export trigger and the slot recycling get wired.

## File map

| File | Role | What we do there |
|---|---|---|
| `src/gb/mappers/gb_camera.v` | camera mapper | **the sensor already works via physical passthrough** |
| `src/gb/cart.v` | physical cartridge interface | route ROM/sensor to the real cartridge |
| `pkg/gb/.../data.json` | APF save slots | define the export (recycling or per-photo) |
| `src/gb/data_unloader.sv` | SD writing via APF | push data to the SD |
| `src/core/core_top.sv` | top level | detect "photo finished", orchestrate |

## Effort reality (honest)

- Building an openFPGA core = **Intel Quartus Prime** (big, Cyclone V FPGA) + a
  build→package→flash→test cycle on the Pocket.
- The remaining work (export + recycling) is real engineering, but with **no blocking unknown left** —
  the hard part (the sensor) is confirmed working.

→ Next phase: install the toolchain and fork the core. The detailed automation plan is in
[Step 4 — Automation design](05-export-recycling-design.md).
