# PocketRoll core — Verilog scaffold

The FPGA side. These modules turn the validated design (docs/04, docs/05) into
droppable Verilog for a **fork of [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)**.

> ⚠️ **Status: scaffold.** Authored from the validated design, **not yet built or simulated**
> (that needs Quartus + a Pocket — see [SETUP.md](SETUP.md)). The logic mirrors the software tools
> we *did* validate (the recycle recipe is byte-perfect vs the real camera). Treat this as a strong
> starting point, not finished IP.

## The three modules

| File | What it does | Confidence |
|---|---|---|
| [`pocketroll_recycle.v`](pocketroll_recycle.v) | Frees one photo slot in cart RAM (`0xFF` + checksum `0x2F`/`0x15` + echo). Verilog port of `tools/gbcam-sav.js free`. | High — exact validated recipe |
| [`pocketroll_export.v`](pocketroll_export.v) | Writes a photo region to an SD slot file via APF target commands. Mirrors the official `core-example-kbmouse-targetdata` write sequence. | High — confirmed pattern |
| [`pocketroll_camera_manager.v`](pocketroll_camera_manager.v) | Orchestrates: detect new photo → export → recycle → repeat. Instantiates the two above. | Medium — integration sketch |

## The loop, in one picture

```
   GB Camera saves a photo
        │ (writes the directory at 0x11B2 in core-served cart RAM)
        ▼
   manager detects it ──► export.v  (photo bytes → SD slot file via APF)
        │                                   │ done
        │                                   ▼
        └──────────────────────────► recycle.v (free the slot: 0xFF + checksum + echo)
                                            │ done
                                            ▼
                                   advance album offset, wait for next photo
                                            → infinite roll
```

## What's left to wire (the integrator's job)

Two things this scaffold deliberately leaves to integration inside the fork — both detailed in
[INTEGRATION.md](INTEGRATION.md):

- **(A) RAM routing** — serve cart RAM (`0xA000–0xBFFF`, non-camera-register accesses) from an
  internal byte RAM, while ROM and camera registers stay on the physical cartridge (sensor
  passthrough already confirmed). This is what lets us edit the photo memory freely.
- **(B) Clock-domain crossing** — `recycle` runs in the cart-RAM clock, `export` in the APF clock
  (`clk_74a`); wrap the `start`/`done` strobes in CDC handshakes.

## Validate the logic first (no Quartus needed)

[`tb/pocketroll_recycle_tb.v`](tb/pocketroll_recycle_tb.v) is a self-checking testbench: it drives
the recycle FSM on a real "2 photos" directory, frees a slot, and asserts the output equals what the
**real camera** produced (checksum `12 EA` — our ground truth). Run it with a tiny install:

```bash
iverilog -o rc_tb core/pocketroll_recycle.v core/tb/pocketroll_recycle_tb.v && vvp rc_tb
# expect: ✅ PASS — recycle output matches the real camera's deletion.
```

A green run here means the most critical module is correct **before** you ever touch Quartus or the
Pocket.

**No Verilog simulator? There's a Node fallback.** [`tb/recycle_model.js`](tb/recycle_model.js) is a
cycle-accurate JS transcription of the recycle FSM (same non-blocking semantics, same RAM timing).
It needs only Node and already **passes** against the camera ground truth:

```bash
node core/tb/recycle_model.js
# idx=6-bit : ✅ PASS  dir=00 FF  checksum=12EA  (138 cycles)
```

> This model earned its keep: it caught a real bug during transcription — `idx` was 5 bits (max 31)
> but the echo loop counts to 36, so the FSM never terminated. Fixed to 6 bits. The model shows both
> the broken (non-terminating) and fixed (PASS) versions.

## Build & flash later

See **[SETUP.md](SETUP.md)** — toolchain install, forking budude2, where to drop these modules,
packaging, and flashing onto the Pocket. The plan of attack (build as-is → add routing → add
recycle → add export) is in [docs/05](../docs/05-export-recycling-design.md#plan-of-attack-once-we-have-quartus).
