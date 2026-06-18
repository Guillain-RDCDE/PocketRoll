# Step 4 — Automation design (SD export + recycling)

> The only remaining job. Every brick is proven; here we **stitch them together**. This document is
> an implementation plan, not final code: what is **confirmed** in budude2's source is marked as such,
> what *we* **propose** is flagged as to-be-validated.

---

## 🟢 In plain English

We want the core, on every photo taken, to do two things on its own:
1. **copy the photo to the SD card**, and
2. **free a slot** so the camera always has room.

The catch: in physical-cartridge mode, the photos live in the **real cartridge's** memory, and writing
into it "over the game's shoulder" is very hairy. The clever idea: keep the **ROM and the sensor** on
the real cartridge (that's where the magic is), but have the **core itself manage the photo memory**.
The core can then modify it calmly — and we already know exactly which bytes to touch.

---

## 🔴 Proposed architecture: "core-served RAM"

### The routing

In physical mode, budude2 passes the **whole** bus through to the cartridge. Our variant splits the
accesses based on what the Game Boy CPU is targeting:

| CPU access | Destination | Why |
|---|---|---|
| ROM (`0x0000`–`0x7FFF`) | **physical cartridge** (passthrough) | the game program |
| Camera registers (`cam_en` mode) | **physical cartridge** (passthrough) | **the sensor** (already confirmed ✅) |
| Photo RAM (`0xA000`–`0xBFFF`) | **core internal memory** | so we can edit it |

This is a **hybrid** of emulated mode (which already serves an internal cartridge RAM — the "Save"
data slot in `data.json`) and physical mode (real ROM/sensor). Technically: in `core_top.sv` /
`gb_camera.v`, route `cram_rd`/`cram_wr` to internal RAM instead of the `cart_tran_*` pins, while
leaving ROM and CAM registers as passthrough.

> ⚠️ **To validate**: that the mapper lets us distinguish "RAM access" from "sensor access" in
> `cam_en` mode (see `gb_camera.v`: `cram_do = cam_en ? <sensor> : cram_di`). The sensor and the RAM
> share the `0xA000`–`0xBFFF` window, toggled by the `cam_en` bit — that bit is exactly the switch.

### Initialization

At startup, **preload** the internal RAM with the cartridge's contents (read its SRAM once over the
bus), so we keep the photos already present. After that, the core owns this RAM.

## The trigger: "a photo was just saved"

The camera writes a new photo then updates the **directory** at `0x11B2` (one entry goes from `0xFF`
to a slot number) and recomputes its checksum `0x11D5`. Our logic **watches writes into the internal
RAM** around `0x11B2`: when a new valid entry appears, a photo is finished. → trigger export then
recycling.

> Simpler alternative: trigger **when the directory is full** (30 entries ≠ `0xFF`), export the
> oldest and recycle it. Less finesse, but trivial to detect.

## SD export — **CONFIRMED** via APF target commands

This is no longer a hypothesis. The official example core
[`open-fpga/core-example-kbmouse-targetdata`](https://github.com/open-fpga/core-example-kbmouse-targetdata)
demonstrates writing a file to the SD from the FPGA: pressing **Select** writes the framebuffer to
slot `0x22`, **creating or overwriting** the asset file `saved.bin`. The APF commands that make this
possible (per the [openFPGA changelogs](https://www.analogue.co/developer/docs/changelog/2-1)):

| Command | Meaning |
|---|---|
| `0180` Data slot read | read a slot from SD |
| `0184` Data slot write | **write a slot to SD** |
| `0190` Get filename | read a slot's filename |
| `0192` Open new file into data slot | **give a slot a new file (→ per-photo names)** |

The write trigger is a tiny state machine — set four registers, pulse `write`, wait for `done`:

```verilog
// from the example core (paraphrased): write core memory to an SD file
target_dataslot_id         <= 16'h22;    // the data slot → its file on the SD
target_dataslot_slotoffset <= 0;         // offset within the file (advance it = append → album)
target_dataslot_bridgeaddr <= 32'h0;     // source address in core/bridge memory
target_dataslot_length     <= 184320;    // number of bytes
target_dataslot_write      <= 1;         // pulse → APF writes the file, then wait for ack/done
```

For PocketRoll the source (`bridgeaddr`) is simply the finished photo's region in the internal RAM,
and `length` is the photo size. **Giant album** = keep one slot and advance `slotoffset` by the
photo size each time. **One file per photo** = same, plus `0192 openfile` to set a fresh name
(`IMG_0001`, `IMG_0002`…). Both are confirmed achievable.

---

For reference, `core_top.sv` exposes these core → host registers (lines 328-340):

```verilog
reg  target_dataslot_write;     // ask the host to write a data slot to the SD
reg  target_dataslot_openfile;  // open/create a file  (param/resp structs to be mapped)
reg  target_dataslot_getfile;
reg  [15:0] target_dataslot_id;
reg  [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
```

Two strategies:

- **One file per photo** *(the dream)*: via `openfile`, write each finished shot to `IMG_0001.bin`…
  on the SD. The cleanest, but requires mapping the param/response structs of `openfile` (sparsely
  documented — to dig out of the agg23/Spiritualized APF).
- **Giant "album" slot** *(simple fallback)*: a nonvolatile data slot much larger than 128 KB, into
  which we **append** each photo. `data_unloader.sv` (MIT, agg23) already streams an internal memory
  to the host. APF persists the whole thing as one big `.sav` that [MugDump](../../MugDump) splits up.

## Recycling — **our validated recipe**

Once the photo is exported, free its slot **in the internal RAM** (see
[Step 2](02-slot-recycling.md)):

```
1. directory entry 0x11B2+i  →  0xFF
2. recompute the checksum 0x11D5/0x11D6   (seeds 0x2F / 0x15, over 0x11B2..0x11CF)
3. copy 0x11B2..0x11D6 into the echo 0x11D7
```

That's exactly `gbcam-sav.js free`, ported to Verilog. It reproduces the camera's deletion **byte for
byte** (validated). The camera sees a free slot → it accepts the next photo → **infinite**.

## Overall diagram

```
            ┌──────────────── physical cartridge ────────────────┐
   GB CPU ──┤ ROM (program)        M64282FP sensor (✅ works)     │
            └───────────────┬─────────────────────┬──────────────┘
                            │ ROM/sensor           │
                 ┌──────────▼──────────┐           │ (passthrough)
                 │   PocketRoll core    │◄──────────┘
                 │                      │
   Photo RAM ───►│  internal RAM (128KB)│──(1) photo finished? (watches 0x11B2)
                 │     │        ▲       │
                 │     │ (2)    │ (3)   │
                 │  export   recycling  │
                 │  APF→SD   recipe     │
                 └─────┬────────────────┘
                       ▼
                  SD card: IMG_0001, IMG_0002, …  →  MugDump
```

## Risks & open questions

1. **RAM vs sensor routing** in `0xA000`–`0xBFFF` (the `cam_en` bit) — to confirm on the real
   cartridge.
2. ~~Can the core write files to SD at all?~~ **Resolved** — confirmed by the official
   `core-example-kbmouse-targetdata`. The only remaining nicety is the `0192 openfile` param struct
   for *per-photo filenames*; the "giant album" fallback needs none of that and is bulletproof.
3. **Internal memory size**: 128 KB of cartridge RAM — emulated mode already serves one, so OK *a
   priori* (block RAM or SDRAM).
4. **Timing**: the export must not stall the GB CPU; do it during idle cycles.

## Plan of attack (once we have Quartus)

1. Fork `budude2/openfpga-GBC`, build the core **as-is**, flash it → validate the toolchain.
2. Add the **internal RAM routing** (ROM/sensor stay physical) → check the camera runs and saves
   normally.
3. Add the **`0x11B2` watch** + the **recycling** (our recipe) → check the infinity without export
   first (photos loop within the RAM).
4. Add the **SD export** (giant album first, per-photo next).
5. Close the loop with [MugDump](../../MugDump).

Each step is testable in isolation on the Pocket. No **blocking** unknown remains — only engineering.
