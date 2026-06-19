# Step A — RAM routing: design (from tracing budude2's core)

Goal: in physical-cartridge mode, serve the **cart RAM** (the 128 KB where photos live) from an
**internal** store we control, while **ROM and the camera sensor stay on the physical cartridge**.
That internal store is what Step B (recycling) and Step C (export) operate on.

## What the trace found

- **The bus.** The emulated GB CPU drives `cart_addr`, `cart_a15`, `cart_rd`, `cart_wr`, `cart_di`,
  `nCS`. In physical mode `core_top.sv` puts these on the cartridge pins and reads back via
  `cart_tran_bank1`: `cart_do = cart_physical_mode ? cart_tran_bank1 : cart_do_backend;` (~L779).
- **The mapper already exists.** `cart_top` (cart.v) is instantiated and contains the camera mapper
  **and an internal 128 KB cart RAM** (used for saves in emulated mode — so it already fits in the
  fabric). It computes the cart-RAM strobes and address:
  - `is_cram_addr = ~nCS & ~cart_addr[14]` (the `0xA000–0xBFFF` window)  ·  cart.v L407
  - `cram_rd = cart_rd & is_cram_addr`  ·  `cram_addr = {ram_bank, cart_addr[12:0]}` (17-bit, 128 KB)
- **But it's gated off in physical mode.** `core_top.sv` feeds `cart_top` the *gated* bus:
  `backend_cart_rd = ~cart_physical_mode & cart_rd` (same for wr). So in physical mode the mapper +
  its RAM are **frozen** — they don't track state and don't store anything.
- **The sensor switch is `cam_en`** (gb_camera.v): writes to `0x4000–0x5FFF` with bit 4 toggle it.
  When `cam_en`, `0xA000–0xBFFF` is the **sensor**; when not, it's **RAM**. `cam_en` is internal to
  gb_camera.v today — we need to expose it.

## The plan (Option A — reuse the mapper, minimal change)

1. **Un-gate `cart_top` in physical mode** so it tracks the mapper and maintains its internal cart
   RAM in parallel with the real cartridge (both see the same writes):
   `backend_cart_rd = cart_rd; backend_cart_wr = cart_wr;`
   (cart_top's ROM reads hit the SDRAM, which is free/garbage in physical mode and **muxed out** —
   we keep ROM physical, so this is harmless.)
2. **Expose `cam_en`** up the hierarchy: gb_camera.v → mappers.v → cart.v → core_top.sv (one output
   port through three modules).
3. **Reroute cart-RAM reads** to the internal store in physical mode, leaving ROM + sensor physical:
   ```verilog
   assign cart_do = (cart_physical_mode & cram_rd & ~cam_en) ? cart_do_backend  // internal cart RAM (photos)
                  :  cart_physical_mode                       ? cart_tran_bank1  // ROM + sensor (cam_en)
                  :                                             cart_do_backend; // emulated
   ```
   Writes can stay as-is (they go to the cartridge **and**, now un-gated, into cart_top's RAM) —
   sensor-config writes still reach the cartridge, RAM writes land in our internal store.

That's the whole functional change: ~1 line un-gate, a `cam_en` port, a 3-way mux.

## What this Step A test proves

Camera still runs, takes a photo, shows it in the gallery — but now **the gallery lives in our
internal RAM**, not the cartridge. (Nothing visibly changes; it's the foundation for B and C.)

## Deliberately deferred

- **Preload.** Without it, our internal RAM starts empty → on first boot the camera sees no photos
  (may offer "clear?"). Accept that for the Step A test (start fresh). Preload (copy the cartridge's
  existing photos in at boot) is a later add: a small FSM that issues `cram_rd` cycles across all
  banks before the CPU runs.

## Risks to watch (before burning a 1 h compile)

- Un-gating cart_top in physical mode must not disturb ROM/sensor passthrough (ROM/sensor stay on
  `cart_tran_*`; only RAM reads switch to `cart_do_backend`).
- `cam_en` timing: it's a registered bit in gb_camera.v; the mux uses it combinationally — fine.
- Confirm cart_top's cart-RAM read latency matches the CPU's expectation in physical mode (it's the
  same CPU/timing as emulated mode, where it already works).
