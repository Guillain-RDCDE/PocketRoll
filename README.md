# PocketRoll 🎞️📸

> Give the **Game Boy Camera** an **infinite roll of film** on the **Analogue Pocket** — the custom
> openFPGA core **and** the full making-of, for curious beginners and hardcore byte-wranglers alike.

> ⚙️ **This repository is a fork of [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)**
> (the openFPGA Game Boy core), extended into PocketRoll. All of budude2's original work lives in
> [`src/`](src/) and [`pkg/`](pkg/); our additions and research live in [`pocketroll/`](pocketroll/).
> Upstream README preserved as [`README.budude2.md`](README.budude2.md).

---

## What's the deal?

The Game Boy Camera (1998, the most gloriously terrible camera in history) only stores **30 photos**.
PocketRoll lifts that limit on the Analogue Pocket: every photo you take with the **real cartridge**
(its real sensor, via the core's physical-cartridge passthrough) gets **archived to the SD card** and
its slot **freed**, so the camera always thinks it has room. Result: **infinite photos**, readable in
[MugDump](https://github.com/Guillain-RDCDE/MugDump).

And since we're not alone on the Moon, **we document everything** — including the stuff written
*nowhere else on the web*.

## 🗺️ Where things live

| Folder | What |
|---|---|
| [`src/`](src/) · [`pkg/`](pkg/) | the openFPGA Game Boy core (budude2's, the base we build on) |
| [`pocketroll/core/`](pocketroll/core/) | our Verilog scaffold (recycle · export · manager) + build helpers + testbench |
| [`pocketroll/docs/`](pocketroll/docs/) | all the research, written twice over (noob track + geek track) |
| [`pocketroll/tools/`](pocketroll/tools/) | zero-dependency Node tools (read/verify/forge saves, RE checksums) |

## 🧠 The research, in one breath

Verified **on real hardware**:

- 🔧 **The Game Boy Camera checksum, fixed** — not a "Magic" seed: **sum seed `0x2F`, xor seed `0x15`**
  over `0x11B2..0x11CF`. → [docs/01](pocketroll/docs/01-game-boy-camera-sram-format.md)
- 🧪 **"Free a slot" recipe** reproduces the camera's own deletion to within 6 bytes (animation noise).
  → [docs/02](pocketroll/docs/02-slot-recycling.md)
- 🗃️ **The Analogue Pocket `.sta` save state format, decoded** — undocumented anywhere else.
  → [docs/03](pocketroll/docs/03-game-boy-camera-saves-explained.md#b-the-analogue-pocket-sta-save-state)
- 🎥 **Sensor passthrough works** — confirmed on hardware: the real cartridge (sensor included) runs live
  in physical-cartridge mode. → [docs/04](pocketroll/docs/04-openfpga-core-architecture.md)
- 🛠️ **Automation design** (SD export + recycling) + Verilog scaffold.
  → [docs/05](pocketroll/docs/05-export-recycling-design.md) · [`pocketroll/core/`](pocketroll/core/)
- 🪵 **The build & debug war story** — every wrong turn flashing this to real hardware (black screens,
  the white-screen hunt) and the trick that saved us: the Pocket's hidden debug log, **no JTAG needed**.
  → [docs/06](pocketroll/docs/06-build-and-debug-war-story.md)
- 📤 **The dump saga** — exporting photos to SD: `target_dataslot_write` works, but the home-made RAM
  mirror was a trap (garbage + freezes). Why the dump must **read the physical cartridge directly**.
  → [docs/07](pocketroll/docs/07-the-dump-saga.md)

## 🗺️ Status

Phase 1 (the infinite roll): research ✅ · scaffold ✅ · recycle logic validated ✅ · sensor confirmed on
Pocket ✅ · **building the custom core** (in progress). Phase 2: a stripped-down "camera-only" ROM.

Build/flash notes: [`pocketroll/core/SETUP.md`](pocketroll/core/SETUP.md) ·
integration map: [`pocketroll/core/INTEGRATION.md`](pocketroll/core/INTEGRATION.md).

> ⚠️ **Build with Quartus Prime Lite 25.1** — the version whose IP (PLLs etc.) this core's source is
> generated for. Other versions (18.1, 24.1) compile cleanly but produce a **black screen** on the
> Pocket. Also: this fork builds the **GB** core, so `core_top.sv` must have `` `define isgbc 0 ``
> (upstream HEAD leaves it at `1`, which builds the GBC variant → wrong BIOS → black screen).

## 🙏 Credits

Core: [budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC) (this fork's base). Camera-format
RE: [Raphaël Boichot](https://github.com/Raphael-Boichot/Inject-pictures-in-your-Game-Boy-Camera-saves),
insideGadgets, [Pan Docs](https://gbdev.io/pandocs/Gameboy_Camera.html). `.sta` extraction:
[Galkon/pokepocket-save-recovery](https://github.com/Galkon/pokepocket-save-recovery).

*All findings verified by hand on real saves. Spotting a difference on another ROM revision? Open an
issue — turns out we're not alone on the Moon.* 🌙
