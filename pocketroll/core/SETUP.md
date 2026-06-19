# SETUP — getting ready to build PocketRoll on your machine

Everything needed to go from "scaffold in the repo" to "custom core running on the Pocket". Do this
once; after that the loop is edit → build → package → flash.

> ⚠️ **The exact Quartus version matters — a lot.** This core's committed IP (PLLs, RAM, DDIO) is
> generated for **Quartus Prime Lite 25.1** (budude2's `7044e75` "upgrade to quartus 25.1"). Building
> with 18.1 or 24.1 compiles cleanly (timing met, no errors) but yields a **black screen** on the
> Pocket — the PLL clocks come out subtly wrong. Use **25.1** and this whole headache disappears.
>
> ⚠️ **Build the GB core, not GBC.** `src/core/core_top.sv` must read `` `define isgbc 0 `` for the
> Game Boy (DMG) core. Upstream HEAD leaves it at `1` (the GBC build) — that bitstream wants
> `gbc_bios.bin`, so packaged as a GB core (with `gb_bios.bin`) it never boots → black screen.

## 1. Tools to install

- **Intel Quartus Prime Lite 25.1** (free) with **Cyclone V** device support enabled during install
  (the Pocket's FPGA is a Cyclone V E). Direct files (download via browser into one folder, run the
  `.exe`): `QuartusLiteSetup-25.1std.0.1129-windows.exe` + `cyclonev-25.1std.0.1129.qdz` from
  `downloads.intel.com/akdlm/software/acdsinst/25.1std/1129/ib_installers/`. ~20 GB installed.
- **Git** (you have it) and a GitHub account (you have `Guillain-RDCDE`).
- An **SD card** for the Pocket and a card reader (you've got this — `E:`).
- **Icarus Verilog** to sim `pocketroll_recycle.v` *before* touching hardware (recommended — saves
  flash cycles). Install: `scoop install iverilog` (no admin) or the official installer from
  bleyer.org/icarus. **Gotcha:** the scoop build's sub-tools (`ivl`/`ivlpp`) need the install's
  `bin` on PATH to find their DLLs — run from an interactive terminal with
  `$env:PATH = "$env:USERPROFILE\scoop\apps\iverilog\current\bin;$env:PATH"` first. (It hangs under
  some headless/automation shells — use a normal terminal.)

## 2. Get the sources

```bash
# fork budude2/openfpga-GBC on GitHub (button), then:
git clone https://github.com/Guillain-RDCDE/openfpga-GBC.git
cd openfpga-GBC
# add PocketRoll's modules:
#   copy core/pocketroll_*.v  ->  src/gb/   (or a new src/pocketroll/)
# add them to the Quartus project file (src/ap_core.qsf) as VERILOG_FILE entries.
```

Keep PocketRoll's modules in *this* repo as the source of truth; copy them into the fork. (Or add
this repo as a submodule of the fork — your call.)

## 3. First build = sanity check (no PocketRoll yet)

Open `src/ap_core.qpf` in Quartus, run **Processing → Start Compilation**. You want a clean
bitstream from the **unmodified** core before adding anything. Then package and flash it (step 5) and
confirm the **real GB Camera cartridge still takes photos** — that's your known-good baseline.

## 4. Add PocketRoll, incrementally

Follow [INTEGRATION.md](INTEGRATION.md)'s "Suggested order". Build after each step. The big one is
**(A) RAM routing**; once the camera runs from internal RAM, the recycle/export modules slot in.

## 5. Package & flash to the Pocket

openFPGA cores are distributed as a `Cores/<Author>.<Core>/` folder on the SD `/Cores/`:

```
# after a successful compile, the bitstream is in output_files/ (e.g. ap_core.rbf_r)
# the openFPGA packaging takes the .rbf + the pkg/ JSON metadata (core.json, data.json, …)
# and lays out /Cores/Guillain-RDCDE.GBCamera/ on the SD card.
```

- Update `pkg/.../core.json` author/name so it doesn't collide with budude2's.
- Add the album/photo data slot to `pkg/.../data.json` (id `0x30`, see INTEGRATION.md).
- Copy the packaged folder to the SD `/Cores/`, eject, boot the Pocket, load the core.

(Reuse a working core's SD layout as a template the first time — match its folder structure exactly.)

## 6. The test that proves it

With the real cartridge + the PocketRoll core:
1. Take **more than 30 photos** without manually deleting.
2. They should keep saving (slots recycled), and pile up as files on the SD.
3. Pop the SD into the PC → open them in [MugDump](../../MugDump).

That's the whole dream, validated end to end.

## Handy checklist

- [ ] Quartus Prime Lite (right version) + Cyclone V support installed
- [ ] Forked + cloned budude2/openfpga-GBC
- [ ] `core/pocketroll_*.v` copied in and added to `ap_core.qsf`
- [ ] Baseline: unmodified core builds, flashes, camera works
- [ ] (A) RAM routing + preload
- [ ] Recycle loop (take >30 photos)
- [ ] Export to SD (album, then per-photo)
- [ ] MugDump reads the result
