# Building & debugging the core — a war story

*Or: how we spent the better part of a weekend staring at a white screen, every wrong turn we took,
and the one trick that finally turned the lights on. If you're grafting onto an openFPGA core and
flying blind, read this **first**. We flew blind so you don't have to.*

> TL;DR — A custom Analogue Pocket core is two jobs: writing the logic (fun) and getting it to
> actually boot and behave on the handheld (pain). Job 2 has a ~1-hour feedback loop and zero
> visibility into the chip. The thing that saved us: **the Pocket has a hidden developer log**
> (`Tools → Developer → Debug Logging`). You can debug a core **without** opening the console or
> buying a JTAG cable. Below is every trap, in the order it bit us.

---

## 🟢 In plain English

Designing the logic was the easy half (that's docs [01](01-game-boy-camera-sram-format.md)–[05](05-export-recycling-design.md)).
The hard half was making the thing *run* on real hardware, because:

- **Every attempt costs ~1 hour.** A full FPGA compile (Quartus) is slow. You change one line, wait
  an hour, and find out if you were right.
- **You can't see inside.** When it's wrong, you usually get a black or white screen. No error
  message. No stack trace. Nothing.

So the whole game becomes: **maximise what each one-hour compile teaches you**, and **find any source
of visibility you can without cracking open a £200 handheld.** Here's what we learned, the hard way.

---

## 🔴 Trap #1 — "It compiled cleanly. Black screen."

The very first build of the *unmodified* core booted to black. No errors, timing met, looked perfect.

We lost hours here before `git log` told the truth. The core ships **pre-generated IP** — PLLs, clock
blocks, DDIO — and that IP is baked for **one specific Quartus version**. Build with a different
version and Quartus silently *regenerates* it, the clocks come out subtly wrong, and you get a black
screen that compiles without a single warning.

```
# The commit that mattered, found via git log on the core repo:
#   "Bump version to 1.4, upgrade to quartus 25.1"
# → the IP is for Quartus Prime Lite 25.1. 18.1 and 24.1 both compile fine and both give black screens.
```

**Two lessons baked into [SETUP.md](../core/SETUP.md):**

1. **Match the exact Quartus version the core was committed with.** Check the core's git history for
   an "upgrade to quartus X" commit. For this core: **Prime Lite 25.1**. Nothing else.
2. **Build the right variant.** This core has a `` `define isgbc `` switch in `core_top.sv`. For the
   Game Boy *Camera* (a DMG game) you want `` `define isgbc 0 `` — the GB build. Upstream HEAD leaves
   it at `1` (the GBC build), whose bitstream wants `gbc_bios.bin`; packaged as a GB core it never
   boots. Another silent black screen.

## 🔴 Trap #2 — "Core setup error"

Bitstream's fine, but the Pocket refuses it with a generic setup error while the reference core loads
perfectly. The culprit is **the folder name on the SD card**. openFPGA cores live in
`/Cores/<Author>.<shortname>/`, and that string has to match the `core.json` metadata **exactly**. We
had `…GBCamera` in the folder and `GBCAM` as the shortname — mismatch, instant failure. Rename the
folder to `<Author>.<shortname>` and it loads.

## 🟢 The baseline win — "it took a real photo"

With the right Quartus, the right `isgbc`, and the right folder name, the unmodified core booted,
talked to the real Game Boy Camera cartridge through the Pocket's cartridge adapter, and **took an
actual photo**. That's the known-good baseline — and you *must* reach it before changing anything,
because it's the only thing that proves your toolchain, your packaging, and your cartridge are all
healthy. Every later "is it me or the hardware?" question gets answered by re-flashing this baseline.

## 🔴 The big one — "everything is white"

Then we added **Step A** (re-routing the camera's photo RAM to an internal store we control — see
[STEP-A-ram-routing.md](../core/STEP-A-ram-routing.md)) and the screen went **completely white**:
white viewfinder, white gallery, nothing. And here's where the war story really starts, because we
chased the wrong thing for *hours*. The honest sequence of false leads:

**False lead #1 — "the internal RAM is empty, preload it."** Reasonable: our internal RAM starts at
zero, the camera sees no valid save, panics. So we preloaded it at FPGA-config time with a real save
(a Quartus `.mif` memory-init file generated from a `.sav`). Quartus confirmed the init was applied.
Still white.

**The turning point — we found the Pocket's hidden log.** `Tools → Developer → Debug Logging` writes
a detailed boot log to `/System/Logs/` on the SD. **This is the single most useful thing in this
entire document.** Suddenly we could see, per boot, exactly which files the Pocket loaded into the
core and what happened at startup — no JTAG, no soldering, no opening the case.

**False lead #2 — "the save load is clobbering our preload."** The log *killed* this theory dead:

```
Slot: checking name [Save] ID [18] idx 1
Play Cartridge selected and this slot's filename is derived from slot index 0, skipping
```

When you play a **physical cartridge**, the Pocket **skips the save slot entirely** — it never loads
*or* saves it. So nothing was overwriting our preload. (Bonus: this is also why you can't cheat and
read the cart's RAM back out as a normal save file — the Pocket won't touch it.)

**False lead #3 — "it's the palette."** The same log showed the Pocket pushing display settings into
the core from a persisted state, including `Custom Palette = ON` with no palette file loaded. For a
DMG game that can blank the screen to white. Plausible! We disabled it (editable straight in
`/Settings/<core>/Interact/…json`, no recompile). Still white. Ruled out.

**Narrowing it down — diff against the reference core.** If our core is white and budude2's runs the
camera, *what's actually different?* We diffed our SD packaging against the reference core's:

```
data.json, interact.json, video.json, audio.json, input.json, variants.json : IDENTICAL
core.json : differs only in author / name / version (cosmetic)
```

Packaging identical → **the bug is 100% in our Verilog**, not in any config file. And a quick sanity
check (run the *reference* core with our cartridge → camera works fine) proved the cartridge was
healthy and our photos intact. Everything now pointed at our ~20 lines of Step A logic.

**The root cause.** Reading the code instead of guessing (free — no compile), we found it in the
core's cartridge module. The read path looks like this:

```verilog
// cart.v — the internal cart RAM read mux
always @* begin
    if (~cart_ready)            // ← if the cart isn't "ready", output 0x00
        cart_do_r = 8'h00;
    else if (cram_rd)
        cart_do_r = cram_do;    // our internal photo RAM
    else
        cart_do_r = rom_do;
end
```

And `cart_ready` only ever rises **after the ROM finishes downloading into the emulator's RAM**:

```verilog
if (dn_write) cart_ready_r <= 1;   // dn_write = a ROM-download write
```

But in **physical-cartridge mode there is no ROM download** — the ROM lives on the real cartridge, so
`dn_write` never fires, so `cart_ready` **never rises**, so the read mux returns **`0x00` forever**.
Our internal RAM was perfectly preloaded and perfectly routed — and then masked to zero on its way
out. The camera read all-zero SRAM, found no valid settings, and blanked *everything* to white.
One stale gate, two days of symptoms.

The fix is three surgical lines: thread the existing `cart_physical_mode` signal into the cartridge
module and stop masking in physical mode —

```verilog
if (~cart_ready & ~cart_physical_mode)  // physical mode: no ROM download, so don't mask our cram
    cart_do_r = 8'h00;
```

*(As of this writing that fix is in the compile queue — but the bug is real and verified directly in
the source: `cart_ready` provably cannot rise in physical mode.)*

---

## 🧰 If you're redoing this — the cheat sheet

Everything above, compressed into the checklist we wish we'd had:

- **Turn on the Pocket's debug log immediately.** `Tools → Developer → Debug Logging` → reads at
  `/System/Logs/`. It shows data-slot loads and boot behaviour. There's also `Pause Load Data` to
  halt before loading (for the JTAG crowd). This is your eyes — use it from minute one.
- **Match the Quartus version exactly.** Find the core's "upgrade to quartus X" commit in `git log`.
  Wrong version = silent black screen, clean compile.
- **Check your build defines** (here: `` `isgbc ``) and that you're packaging the matching BIOS.
- **Name the SD folder `<Author>.<shortname>`,** matching `core.json` to the character.
- **Reach a known-good baseline** (unmodified core takes a photo) *before* touching anything.
- **Diff your packaging against a known-good core.** Rules a whole class of bugs out in seconds and
  tells you whether to look at config or at Verilog.
- **Read the code before you burn a compile.** At ~1 hour each, an hour of reading that saves one
  blind compile already broke even. Most of our real progress came from reading, not flashing.
- **No JTAG required.** People will tell you to open the Pocket and hook up a USB Blaster for
  SignalTap. You can get *remarkably* far on the debug log alone, the reference-core diff, and
  actually reading the source. We never opened ours.

The meta-lesson: on a platform where each iteration costs an hour and you can't see inside, the
winning move isn't more compiles — it's **manufacturing visibility** from everything around the chip
(the log, the diff, the source) so that every compile you *do* spend is aimed at a fact, not a hunch.
