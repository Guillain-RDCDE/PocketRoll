# An Infinite Roll

### Teaching a 1998 Game Boy Camera to shoot forever — on an FPGA, with no PC in the field.

*This is the true story of how PocketRoll came to be: a two-week descent through a save
format that erases itself if you cheat, a chip that boots to a white screen for reasons that
turn out to be the wrong version of a compiler, a bug that cost three days and was fixed by
changing one character, and a ROM that nobody on Earth had ever disassembled.*

> 🇫🇷 **Cette histoire existe aussi en français** → [STORY.fr.md](STORY.fr.md) · 🌐 **Illustrated web version (EN/FR)** → [read it on GitHub Pages](https://guillain-rdcde.github.io/PocketRoll/)

> **How to read this.** The narrative runs straight through — you can read the whole thing
> and never touch a hex address. But every time the story hits something worth seeing up
> close, there's a **🔬 deep-dive box** you can unfold: the actual bytes, the Verilog, the
> disassembly, the register offsets. Skip them and you get a story. Open them and you get the
> schematics.

---

## Prologue — Thirty Photos

In 1998, the Game Boy Camera could hold thirty photos. Not thirty per session — thirty,
*total*, forever, until you deleted some to make room. The cartridge carried a tiny chip with
space for thirty frames and a program that counted, politely, to thirty, and then refused.

I wanted infinite.

Not the "plug it into a PC and clear the roll" kind of infinite — that already existed, and it
needed a PC. I wanted to stand in a field with nothing but an Analogue Pocket, the original
1998 cartridge, and an SD card, and shoot until the card filled. No laptop. No cables. Thirty
becomes infinite, and the camera never finds out.

The problem is that the camera is telling the truth. There really are only thirty slots, and
the program really does refuse the thirty-first. To lie to it convincingly, I'd have to reach
into three different machines stacked inside each other:

- a **ROM** — the camera's program — that can see a camera sensor but has no concept of a file;
- a **cartridge** that physically holds the sensor chip and thirty frames of memory;
- and, underneath both, a **field-programmable chip** pretending, gate by gate, to be a Game Boy.

That third layer is the one nobody expects, and it's the one that makes this possible at all.
The Analogue Pocket doesn't emulate a Game Boy in software — it *becomes* one, by loading an
FPGA "core" that wires up a Game Boy out of raw logic. And crucially, one of those cores —
budude2's `openfpga-GBC`, itself descended from the MiSTer Game Boy core — can run a **real
cartridge plugged into the Pocket**, passing the live bus straight through to actual 1998 silicon.

Which meant the plan, absurd as it sounded, had a shape: leave the cartridge and its sensor
completely untouched and physical, and rewrite *the Game Boy underneath it* to notice each photo,
copy it to the SD card, and quietly recycle the slot. This is the story of teaching that stack to
lie — and of every time it lied back.

<details>
<summary>🔬 The save that wipes itself if you cheat</summary>

Before touching a single gate, I had to understand what a photo *is* on this cartridge. The
128 KB of save RAM is laid out as an 8 KB header followed by thirty 4 KB slots (`0x2000 + i*0x1000`).
The camera tracks which slots are used with a **30-byte summary vector at `0x11B2`** — one byte per
slot, the value being that photo's display number, `0xFF` meaning "empty/deleted." Immediately after
it sits the literal ASCII string `"Magic"` (`0x11D0`–`0x11D4`), then a **two-byte checksum** at
`0x11D5`/`0x11D6`, then a 37-byte **echo** copy of the whole management block.

Here's the trap. The checksum isn't a CRC. It's a running **sum seeded at `0x2F`** and an **XOR
seeded at `0x15`**, taken over the summary bytes *alone* — `"Magic"` is deliberately excluded from
the sum. I reverse-engineered those seeds by hand and then confirmed them against ground truth: I
deleted one photo on the real camera and dumped the save before and after. Before: two photos,
summary `00 01`; after: one photo, summary `00`, checksum `0x12 / 0xEA`. My formula, run on the
"after" summary, produced exactly `0x12 / 0xEA`. (There's a *second* management block at `0x1000` for the
minigame/animation state, same `0x2F`/`0x15` seeds, its own echo — that one nearly threw me until I
realised one drifting byte was just animation state, not roll state.)

Now the punchline, the fact that dictated the entire architecture: corrupt the checksum, or drop
the `"Magic"` marker, and the camera doesn't merely reject the save. **On the next boot it erases
the entire cartridge.** Suicide code. So you *cannot* free a slot by rewriting the save from
outside and hoping the camera accepts it — any edit that makes a slot look free without the camera's
own bookkeeping is a corrupted save, and a corrupted save is a dead cartridge. The overwrite has to
come from *inside* the ROM's own logic. Which, months later, is exactly what forced me to disassemble
a ROM nobody had ever disassembled. But I'm getting ahead of myself.

</details>

---

## I. The Save That Fights Back

The save format took a week to fully trust, and most of that week was spent being wrong in
instructive ways.

The public documentation for the Game Boy Camera save — and there is some, thanks to people like
Raphaël Boichot and insideGadgets who've spent years on this hardware — got the checksum subtly
wrong, or described a different ROM revision (Hello Kitty, or the "Debagame" prototype, which stores
its roll completely differently). Every time I built a tool on somebody else's description, it
disagreed with my actual dumps by a handful of bytes. So I stopped trusting descriptions and started
trusting the cartridge: forge a save, load it, see what the *camera* does to it, and let the
disagreement teach me.

That loop — forge, load, observe, diff — became the method for the entire project. It's slow, it's
humbling, and it's the only thing that works when the documentation and the silicon disagree and
one of them is lying.

By the end of the week I had a small library that could read the roll, verify both checksums,
and free a slot the way the camera itself would — recomputing the checksum, copying the echo,
leaving the image bytes alone. It passed a self-test against ground truth to within six bytes out
of 131,072, and those six bytes turned out to be an animation timestamp, not roll data. The
recycling recipe was correct.

There was just one problem, and it was the one from the prologue: I now knew *exactly* how to
edit the save, and I also knew that editing the save from outside was a trap. The recipe was
correct and useless at the same time. To actually use it, something *inside* the running system
would have to apply it — which meant getting inside the running system.

---

## II. White Screen

You do not casually "get inside" an Analogue Pocket. There's no operating system to log into, no
debugger, no printf. There's a compiler (Intel's Quartus, a 20-gigabyte behemoth), a fork of a
Game Boy core written in Verilog and VHDL, and a roughly one-hour feedback loop between "I changed
a line" and "I find out if the Pocket agrees."

I forked budude2's core, compiled it completely unchanged, packaged it, copied it to the SD card —
and got a black screen.

Then I got a *different* black screen. Then a white one.

<details>
<summary>🔬 Two black screens, two unrelated causes</summary>

The first black screen was a packaging mistake and a good lesson in how unforgiving openFPGA is.
A core's folder on the SD card must be named *exactly* `<author>.<shortname>`. I'd named the folder
`…GBCamera` but set the shortname to `GBCAM`, and the Pocket rejected it with a generic "core setup
error." I isolated it by swapping in the *official* bitstream and watching it fail identically — so
it wasn't my build, it was the name. Renamed to `Guillain-RDCDE.GBCAM`, and it loaded.

The second black screen was subtler and cost real time. My build *loaded* and stayed dark. Timing
was clean, no critical warnings. Two things were wrong at once:

1. The upstream `core_top.sv` leaves `` `define isgbc 1 `` — it builds the Game Bo**y Color** core,
   which demands a `gbc_bios.bin`. Packaged as a plain Game Boy with `gb_bios.bin`, it can't boot.
   One character: `` `define isgbc 0 ``.
2. Even with that fixed, it stayed dark unless I built with **Quartus Prime Lite 25.1** specifically.
   The committed IP and PLL blocks were generated against that version; build with 18.1 or 24.1 and
   they compile cleanly but synthesise *subtly wrong clocks* — the FPGA runs, produces no valid
   video, and shows you nothing but black. There is no error. There is only the dark.

The packaging itself is its own small ritual: openFPGA wants the bitstream **bit-reversed** (every
byte's bits flipped) and renamed `gb.rbf_r`. I wrote a tiny `reverse_rbf.js` to do it, and that
script has run on every single build since.

</details>

The white screen, when it finally came, was progress: white means the core is alive and running
the camera's boot, it just isn't seeing a valid save. And that was the moment the whole thing
stopped being theory. On June 19th, my own custom Game Boy — compiled from source on my machine,
bit-reversed, copied to an SD card — booted the real Game Boy Camera cartridge and **took a photo.**

The stack was standing. Now I had to teach it to lie.

---

## III. The Bug That Ate Three Days

Here is the part I'm least proud of and learned the most from.

The goal now was simple to state: when the camera takes a photo, copy the 128 KB of save RAM out
to the SD card. I knew the Pocket could write files — the APF framework has commands for a core to
push data to the host. I knew where the photos lived. It should have been an afternoon.

It was not an afternoon.

I tried mirroring the cartridge RAM into internal memory and dumping that: garbage. I tried
bus-mastering — pausing the Game Boy and driving the cartridge bus myself to read all sixteen banks:
garbage. I tried the Pocket's own native save-on-exit: *the same garbage.* Different techniques,
weeks apart, all producing byte-for-byte the same wrong output. When every road leads to the same
wrong place, you are not taking wrong roads. You are reading from the wrong place.

The tool that cracked it was stupid and perfect: a **witness file** full of `0xAA`. I filled the
save with `0xAA`, loaded it, took a photo, dumped. If my dump came back full of `0xAA`, my *capture*
was broken. If it came back full of something else, my *read path* was broken. The dump came back
98.6% `0xFF` with `0x0000` equalling `0x2000` — not `0xAA` at all. So the file I was reading wasn't
even the file I thought I'd written. I wasn't looking at my dump. I was looking at some *other* file
entirely, and I had been the whole time.

<details>
<summary>🔬 One character: 0x2 → 0x3</summary>

The Pocket's data slots have an `address` field — the location in the core's memory map that the
Pocket reads from when it saves that slot to SD, and writes to when it loads. My dump buffer was
exposed to the Pocket's bridge at `0x30000000`. But the slot I'd configured was marked `nonvolatile`,
and its `address` still pointed at `0x20000000` — the *save-handler's* region, the plumbing designed
for the normal, Pocket-coordinated save of a virtual cartridge.

So on every exit and every sleep, the Pocket dutifully performed a "native save": it read
`0x20000000` (the save handler, full of nonsense in physical-cartridge mode) and **overwrote my
dump file with it.** I was always, every time, reading back the save handler's garbage — never my
carefully captured buffer. Every technique had worked; I'd just never once *looked at its output*.

The fix was to point the slot's `address` at `0x30000000` — my buffer. One hex digit. `0x2` → `0x3`.
Three days.

The lesson has stayed with me past this project: when *all* your approaches fail *identically*, stop
improving the approaches. You're reading or writing the wrong location, and the sameness of the
failure is the clue.

</details>

With that one digit fixed, the dumps came alive. A passive **snoop** — watching every byte the
camera itself read off the cartridge and copying it aside — produced a byte-valid save with real
photos in it: my face, my desk, a piano. To catch *all* sixteen banks (a 128 KB buffer won't fit in
the FPGA's block RAM — it's saturated by the core's own cartridge RAM) I repurposed the Pocket's
unused 128 KB of external SRAM as the capture buffer. And then, because scrolling through every photo
by hand to make the camera read it was tedious, I resurrected the bus-master I'd abandoned — and this
time, having finally *seen* its real output, made it work in one button.

<details>
<summary>🔬 Don't invent a clock for someone else's bus</summary>

The bus-master reads the cartridge by driving the address/bank lines itself while the Game Boy is
paused. My first version sampled the returned data at `cart_phi_fall` — the falling edge of the
cartridge's own PHI clock, which seemed like the obvious place. Result: 94.8% correct, real photo
data, but the directory bytes read back as `00` and the checksum failed. A timing-margin miss.

The fix was to stop inventing a sample point and *borrow the one that already works*: the Game Boy
core latches cartridge reads at its CPU clock enable, `ce_cpu`. Sample there — at the exact edge the
real gb uses — and the directory is perfect, the checksum matches, the echo matches. One button, no
scrolling, sixteen banks, valid save.

The principle rhymes with the whole project: when you're a guest on hardware you don't fully
understand, don't synthesise your own timing. Find the timing the system already trusts and stand
exactly on it. (This exact lesson comes back, one final time, in the last chapter — for a bus I
*wasn't* even driving.)

</details>

By late June the dump was solid — and then it got beautiful. The intuition, when it came, felt like
a gift: *save states already write to the SD card in the middle of gameplay and resume without a
hitch. Stop fighting the pause. Use the thing that already pauses cleanly.* The Pocket's native save-state freezes the Game Boy at a safe point, serialises its
memory, and resumes — no freeze, no relaunch. I made two changes so it would capture the *photos*
(the sensor writes them into the cartridge off the CPU bus, so the native mirror never sees them),
and suddenly the dump was a single button press that never interrupted anything. MugDump, my
companion decoder, learned to read the `.sta` save-state file directly. The field half of the dream
worked: shoot, save-state, keep going, decode at home.

Everything worked except the one thing the whole project was named for. The camera still stopped at
thirty.

---

## IV. Patching a ROM Nobody Disassembled

I had spent a month building a machine that could dump photos infinitely and recycle slots
flawlessly — and it was blocked by a program from 1998 that counted to thirty and said no.

My first instinct was to keep going the way I'd been going: reach into the save and free a slot. But
the prologue's trap was absolute — edit the save from outside and the cartridge commits suicide on
reboot. The community's own reverse-engineering (Boichot's *Inject-pictures* work) confirmed it in
detail: the "full" check scans the summary vector, and forging a free slot fails the checksum or
loses the `"Magic"`, and then the whole roll is wiped. Editing the RAM is a dead end by design.

The realisation, when it came, reframed everything: **the sensor was never the problem.** Photos
already worked — the passthrough was perfect. The only obstacle was a piece of *software* — the
ROM's "film full" logic — and software can be patched. Not by reflashing the cartridge (I refused to
open or modify the physical hardware), but by intercepting the ROM reads that already flow through
my FPGA core and *substituting different bytes at a few specific addresses.* Same trick as snooping
bank selects, pointed at a new target: rewrite the program as the Game Boy reads it.

There was one obstacle to that plan: to patch the "film full" routine, I had to *find* it. And it
had never been found.

<details>
<summary>🔬 Disassembling the Game Boy Camera, because no one else had</summary>

I ran a deep, wide literature search — dozens of parallel agents across the homebrew, ROM-hacking,
and preservation communities — for a disassembly of the Game Boy Camera's photo-management logic.
There isn't one. There are disassemblies of the *minigames*, tools that *read* the save, projects
that *replace* the whole ROM (untoxa's `gb-photo`), but nobody had published the retail firmware's
"is the roll full, and where's a free slot" logic. So I wrote a small LR35902 disassembler and did
it myself, against both the US ("GAMEBOYCAMERA") and Japanese ("POCKETCAMERA V1.1") retail ROMs.

Every piece of photo management lives in **ROM bank `$02`**, at byte offsets that are *identical*
between the US and JP cartridges — a strong sign these are the canonical routines. The key finds:

- **`02:444D`** — the shared "scan the roll" loop. It walks the 30-entry directory copied into work
  RAM at `$D563`, comparing each entry against `A`. Call it with `A = $FF` and it finds a *free*
  slot; call it with a photo number and it finds *that photo*. It returns the index with carry clear
  on a hit, or `A = 0` with carry **set** when nothing matches. It is *generic* — which is exactly
  why patching it directly is dangerous.
- The checksum routines at `02:431F`/`432F`, which the ROM's own commit path recalculates — meaning
  a byte-patch that goes through normal write flow gets a *correct* checksum for free, with **no
  suicide-wipe.** This is the loophole that makes the whole approach survivable.

</details>

Finding the routine was the beginning, not the end. What followed was four hardware iterations, each
one proving my model of the ROM slightly wrong and teaching me the next layer down.

The first patch neutralised the "full" refusal at the three photo-writing sites. Result on hardware:
the thirty-first shot displayed **"no blank frame"** and stopped anyway. So there was a guard *upstream*
of the write sites. The second patch moved to the shared scan at `02:444D`. Result: *no change at all*
— which was itself the clue. If patching the scan changed nothing, the guard wasn't consulting the
scan.

Then the observation that cracked it: delete photo #1 on the camera and photo #2 becomes #1. The
roll *renumbers itself*. That's not a scan. That's a **counter.**

<details>
<summary>🔬 It was never a scan. It was a counter at $D561.</summary>

After every roll operation, the ROM runs `02:4466`: it reloads the directory from `$B1B2` into work
RAM at `$D563`, **renumbers and compacts it** (`$447F`–`$4497` — this is the "sliding roll" I could
see when deletions renumbered), then counts the occupied slots:

```
02:4499   LD BC,$1E00        ; B = 30 (loop), C = 0 (count)
          ... loop 30× ...   ; LD A,(HL+); CP $FF; INC C if occupied
02:44A9   LD ($D561),A       ; the ONLY writer of $D561
```

Every "film full" gate in the entire ROM — spread across banks 4, 6, 7 and the write-site preambles
— is the same three instructions: `LD A,($D561); CP $1E; jump-if-not-less → full`. They all read one
byte. So there was one true chokepoint, and it wasn't a scan at all.

The fix is a single byte. Cap the counting loop at 29 instead of 30 — offset `$049B`, `$1E` → `$1D`.
Now `$D561` can never reach 30, every "full" gate passes, and the camera never refuses. On hardware,
shot #31 no longer said "no blank frame." **The film was infinite.**

But "infinite" via a cap-at-29 just means it overwrites the same slot forever. For a *true* roll —
recycle oldest-first, 0→29→0 — I redirected the free-slot search into a small routine injected into
free space at `$7AB5` (1,355 unused `$00` bytes in bank `$02`, common to both ROMs). It returns the
slot of the *oldest* photo (display number 0 in `$D563`); because `02:4466` renumbers after every
shot, "number 0" rotates across the physical slots, and the writes cycle through all thirty. The
overlay, in full:

- **(a)** count cap — `$049B`: `1E` → `1D`
- **(b)** redirect — `$0459`–`$045B`: `AF 37 C3` → `C3 B5 7A` (`JP $7AB5`)
- **(c)** injected routine — `$3AB5`+ : test `A` first so *only* the free-slot search (`A=$FF`) is
  diverted; a by-number lookup still returns the ROM's honest "not found" (diverting *those* corrupts
  state and crashes — a lesson from a later save-state crash I had to fix).

</details>

On June 30th I shot past thirty into an empty album, and the photos landed on *different slots* —
30, then 29, then 28, arriving from the far end and rotating through. The roll was cycling. Thirty
physical slots, endlessly refreshed, always holding the thirty most recent photos. **The film was
infinite, in software alone, with the cartridge and its sensor completely untouched.** The "reset
the roll" problem — the single open question that had haunted every design document — wasn't solved.
It was *deleted.* You never reset a roll that recycles itself.

The dream, on paper, was complete. There was one wart left, and it was hiding in the one feature I'd
leaned on hardest.

---

## V. Split in Two

Every time I triggered a save-state to dump the photos, the screen glitched, came back for about a
millisecond, **split in two**, and froze. I had to quit and relaunch the core to keep shooting. The
dump itself was fine — the `.sta` file was already written and valid before the freeze — but the
*resume* was broken. Batch after batch, I was relaunching by hand.

I could have shipped it like that. It worked; it was just ugly. But "split in two, then freeze" is
too specific a symptom to leave alone. So the last chapter of this project is a debugging story with
no debugger — because I never opened the Pocket, never attached a probe, and worked entirely from the
device's own log files and the source of the core.

First I proved what it *wasn't.* It happened with my infinite-roll overlay switched **off** — meaning
the running core was byte-for-byte the stock upstream core. So it wasn't my ROM patch. Timing was
clean (positive slack). It reproduced on a freshly-erased album. The save data was provably valid.
Whatever was wrong, it was in the *resume of the emulated Game Boy itself*, and it had probably been
wrong all along — I'd just never noticed, because I'd been relaunching anyway.

The phrase "split in two" was the tell. The Game Boy Camera's interface uses mid-frame raster
effects — it changes scroll and window registers *while the screen is drawing.* A picture that splits
horizontally and freezes is a display that resumed at the wrong scanline, or a CPU that derailed
mid-frame and stopped updating the screen. So I went into the core and asked the one question that
mattered: **what, exactly, is still running during a save-state pause that shouldn't be?**

<details>
<summary>🔬 The physical cartridge clock never stopped</summary>

In physical-passthrough mode, the emulated Game Boy CPU is *not* wait-stalled by the cartridge
(`cart_wait_n = 1'b1`). A cartridge read is correctly timed only because two counters, both ticking
off the same system clock, stay in a fixed phase relationship:

- `clkdiv`, inside `speedcontrol` — the phase generator for the CPU clock enable `ce_cpu`;
- `cart_phi_counter`, in `core_top` — the physical cartridge's PHI clock.

During a save-state the Game Boy is paused: `speedcontrol` **freezes `clkdiv`**. But `cart_phi` was
reset only on hard reset or a speed change — *never on the pause.* So while the save-state machinery
spent its many cycles serialising the whole console state, **`cart_phi` kept free-running.** On
resume, `clkdiv` restarted from its frozen phase while `cart_phi` sat at an arbitrary, drifted phase.
The very first cartridge read after resume latched out-of-phase data; the CPU read garbage, jumped
somewhere wrong, and froze — and because it stopped writing scroll/LCDC registers mid-frame, the
camera's raster UI split in two. Every symptom, explained by one un-frozen counter. And it explained
why it had "always glitched": this freeze was never needed upstream, where save-states target
SDRAM-loaded ROMs, not a live physical cartridge on a running clock.

The fix is to freeze `cart_phi` on *exactly* the cycles `clkdiv` is frozen. I exposed
`speedcontrol`'s internal `PAUSED` state as a new `pause_active` output — carefully, because the pause
has a 15-cycle tail on release, and freezing `cart_phi` even a few cycles off would reintroduce the
drift — and held `cart_phi` whenever it's asserted. Residual phase error: about one system clock out
of thirty-two, ~3%, comfortably inside the PHI-high data window. And because `speedcontrol` only
enters PAUSED when no cartridge access is in flight, the Game Boy never freezes mid-transaction — on
resume it starts a fresh, correctly-timed cycle. `cart_phi` was the *only* physical signal that
drifted; freeze it, and the two clocks resume in lockstep.

This is the `ce_cpu` lesson from Chapter III, returned in its final form. Back then I learned not to
invent a clock for a bus I was driving. Here the bug was the mirror image: a bus I *wasn't* driving,
whose clock I'd simply forgotten to stop.

</details>

Two files changed. A new signal exposed from the speed controller; a handful of lines in the top
level to freeze the cartridge clock alongside the CPU clock. I compiled, bit-reversed, copied to the
SD card, flashed it, took a few photos, and pressed **Analogue + Up**.

The screen dipped, and came back. Whole. No split. No freeze.

I kept shooting.

---

## Epilogue — Infinite

The workflow now fits in one breath and needs nothing but the device in your hands:

**Shoot thirty. Save-state — it resumes clean. Shoot thirty more; the oldest slots recycle, the
camera never refuses. Save-state again. Decode at home with MugDump.** No PC in the field. No reset.
No relaunch. A 1998 cartridge, its original sensor entirely untouched, taking an unlimited roll of
photos onto an SD card, because the Game Boy underneath it has been quietly taught to lie.

I want to be honest about what this was, because that's the part worth keeping. It was not a clean
march. It was a save format I had to distrust into submission, three days lost to a single hex digit,
four hardware iterations to learn that a "scan" was a "counter," a ROM I had to disassemble because
the world hadn't, and a final freeze debugged with nothing but log files and a theory about a clock.
Every real breakthrough in it came the same way: when everything failed *identically*, I was looking
in the wrong place; when I was a guest on hardware, I borrowed the timing it already trusted instead
of inventing my own. Those two ideas, over and over, are the whole engineering spine of this project.

The infinite roll is the first brick. There's a second one I can see from here — a purpose-built
"pure camera" homebrew ROM running on this same core, all viewfinder and exposure and none of the
1998 minigame cruft. But that's another story, and this one is finished. The film doesn't end
anymore.

Thirty, forever.

---

### The trail, if you want to walk it

The technical write-ups, in order, live under [`pocketroll/docs/`](pocketroll/docs/):

- [**01 — SRAM save format**](pocketroll/docs/01-game-boy-camera-sram-format.md) — reverse-engineered and ground-truthed.
- [**06 — build & debug war story**](pocketroll/docs/06-build-and-debug-war-story.md) — white screens, `isgbc`, Quartus versions.
- [**07 — the dump saga**](pocketroll/docs/07-the-dump-saga.md) — dead ends, the `0xAA` witness, the one-digit bug.
- [**09 — the fluid dump via save-state**](pocketroll/docs/09-the-fluid-dump-via-savestate.md).
- [**10 — state & roadmap**](pocketroll/docs/10-state-and-roadmap.md) — the reset frontier, and the decision to patch the ROM.
- [**11 — ROM disassembly & overwrite overlay**](pocketroll/docs/11-rom-disasm-overwrite.md) — the home-grown disassembly, bank `$02`.
- [**12 — save-state resume fix**](pocketroll/docs/12-savestate-resume-handoff.md) — the physical-cart PHI desync and its fix.

The core itself is a fork of budude2's `openfpga-GBC`, which is the reason any of this was possible;
the save-format reverse-engineering stands on work by Raphaël Boichot, insideGadgets, and the wider
Game Boy Camera preservation community.
