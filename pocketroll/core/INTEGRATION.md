# Integrating PocketRoll into the budude2 fork

Precise graft points for wiring the [`core/`](.) modules into a fork of
[budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC). File/line references are from the
state analysed in [docs/04](../docs/04-openfpga-core-architecture.md) — re-check against the commit
you fork (they drift).

> Reminder of what's already done for us: in physical-cartridge mode the core passes the **whole GB
> bus** (incl. the M64282FP **sensor**) through to the real cartridge — confirmed on hardware. We
> only add memory routing + the export/recycle loop.

## (A) RAM routing — the key change

**Goal:** cart-RAM accesses (`0xA000–0xBFFF`, when *not* in camera-register mode) hit an **internal
byte RAM** we control; ROM and camera registers stay on the physical cartridge.

- The mapper already separates the cases. In `src/gb/mappers/gb_camera.v` the `cam_en` bit is the
  switch: `cram_do = cam_en ? <sensor> : cram_di`. **RAM access = `cram_rd`/`cram_wr` with
  `cam_en == 0`; sensor access = `cam_en == 1`.**
- In `src/core/core_top.sv`, the physical-mode routing (`cart_physical_mode ? cart_tran_bank1 :
  cart_do_backend`, around L779) currently sends *everything* to the cartridge pins. Add a third
  path: **RAM reads/writes (`cam_en == 0`, address in `0xA000–0xBFFF`) ⇒ internal RAM**, leaving ROM
  and `cam_en == 1` accesses on `cart_tran_*`.
- **Preload:** on cartridge boot, read the cart's existing SRAM once (over the bus) into the internal
  RAM, so already-present photos survive.
- Expose a **second master port** on that internal RAM for `pocketroll_recycle` (arbitrated against
  the GB CPU — only act during VBlank / when the CPU is not touching cart RAM).

Internal RAM size = 128 KB (`0x20000`). Emulated mode already keeps a cart-RAM store (the
`data.json` "Save" slot, id 18) — reuse that infrastructure (block RAM / SDRAM).

## (B) Snoop for the manager

Wire the internal-RAM **write port** to the manager's snoop inputs:

```
.dir_wr      ( <internal cart RAM write enable> ),
.dir_wr_addr ( <internal cart RAM write address, 17-bit> ),
.dir_wr_data ( <internal cart RAM write data, 8-bit> ),
```

The manager filters to the directory window `0x11B2..0x11CF` itself.

## (C) Export — APF target interface

`pocketroll_export` / the manager drive the **core → host** target data-slot registers already
present in `core_top.sv` (analysed around L328-340). Connect them straight through to the
`core_bridge_cmd` instance:

```
target_dataslot_write / _id / _slotoffset / _bridgeaddr / _length   (manager -> bridge)
target_dataslot_ack / _done / _err                                  (bridge -> manager)
```

Add a **nonvolatile data slot** for the album/photos in `pkg/gb/Cores/budude2.GB/data.json`
(give it an id, e.g. `0x30`, matching `PHOTO_SLOT_ID`), large enough for the album. For per-photo
files, also map the `0192 open new file` param/response structs (the one remaining nicety).

`bridgeaddr` must be the address of the photo region **as seen on the APF bridge** — set
`RAM_BRIDGE_BASE` (manager param) to wherever the internal cart RAM is exposed to the bridge.

## (D) Instantiate the manager in `core_top.sv`

```verilog
pocketroll_camera_manager #(
    .RAM_BRIDGE_BASE ( /* bridge base of internal cart RAM */ ),
    .PHOTO_BYTES     ( 32'h0000_1000 )   // whole slot; 0x0E00 = image only
) u_pocketroll (
    .clk(clk_sys), .rst_n(reset_n), .enable(is_gb_camera_cart),
    .dir_wr(...), .dir_wr_addr(...), .dir_wr_data(...),
    .rc_ram_addr(...), .rc_ram_rd(...), .rc_ram_rd_data(...), .rc_ram_wr(...), .rc_ram_wr_data(...),
    .target_dataslot_write(...), .target_dataslot_id(...), .target_dataslot_slotoffset(...),
    .target_dataslot_bridgeaddr(...), .target_dataslot_length(...),
    .target_dataslot_ack(...), .target_dataslot_done(...), .target_dataslot_err(...),
    .photos_exported()
);
```

`is_gb_camera_cart` = detect the Game Boy Camera (mapper type / cartridge header) so PocketRoll only
engages for that cart.

## (E) Don't forget the clock domains

`recycle` is happy in the cart-RAM/`clk_sys` domain; `export` lives in `clk_74a` (APF). In the
scaffold the manager uses one clock for clarity — split it, and synchronise the `start`/`done`
strobes that cross domains. Keep `target_dataslot_*` entirely in `clk_74a` like the example core.

## Suggested order (each step testable on the Pocket)

1. Fork + build budude2 **unchanged** → flash → confirm the camera still works. *(toolchain check)*
2. Add **(A) RAM routing** + preload → camera runs, saves to internal RAM. *(no behaviour change yet)*
3. Add `pocketroll_recycle` + the manager's detect→recycle (no export) → take >30 photos, the slots
   loop forever. *(proves the infinite recycle on hardware)*
4. Add `pocketroll_export` → photos land on the SD. *(album mode first)*
5. Per-photo filenames via `0192 openfile`, then close the loop with [MugDump](../../MugDump).
