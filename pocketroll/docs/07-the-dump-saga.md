# Exporting to SD — the dump saga

*Or: every dead end we hit trying to get the camera's photos onto the SD card, so the next person
goes straight to the one approach that actually works. Part two of the war story
([part one is here](06-build-and-debug-war-story.md)).*

> TL;DR — Writing a file to SD from an openFPGA core works via the APF **`target_dataslot_write`**
> command, and that part went smoothly. The hard part was the **source data**. We tried to mirror the
> camera's RAM into the core and read it back through the stock save path — and chased garbage for a
> day. The lesson: **don't read the camera's RAM through a home-made mirror; read the physical
> cartridge directly.** Also: a data slot the core writes to needs a **non-zero size** first, or the
> write silently fails.

---

## 🟢 In plain English

The dream: walk around with just the Analogue Pocket + the Game Boy Camera cartridge, shoot forever,
and have every photo land on the SD as a file. No PC in the field.

To get there we changed strategy. Our first plan (["Step A"](04-openfpga-core-architecture.md)) was to
serve the camera's photo RAM from *inside* the core so we could read/recycle it. It half-worked but
fought us at every turn (and the live sensor writes happen on the cartridge, **off the data bus we can
see** — so an internal copy never sees the live image). So we flipped it:

> **Leave the camera 100% on its real cartridge** (where it already works perfectly), and just
> **(1) dump** the cartridge RAM to SD and **(2) reset** the film when it fills. Repeat → infinite roll.

This doc is about brick (1), the dump — and the three dead ends before the right answer.

---

## 🔴 The part that worked: writing a file to SD

The core can ask Pocket to write a file from a region of its memory, using the APF target command
**`0x0184` (`target_dataslot_write`)**. You point it at a data slot (a file), a bridge address to read
from, and a length:

```verilog
target_dataslot_id         <= 16'd48;        // a slot defined in data.json
target_dataslot_bridgeaddr <= 32'h2000_0000; // where the data lives in the bridge space
target_dataslot_length     <= 32'h0002_0000; // 128 KB
target_dataslot_write      <= 1'b1;          // fire; wait for ack, then done
```

The Pocket's debug log (`Tools → Developer → Debug Logging`, see
[part one](06-build-and-debug-war-story.md)) shows it accept the command:

```
Target: New command [0184]
Target: Write from BRIDGE 0x20000000 ... len 0x00020000 ... slot [PocketRoll] ... pocketroll.sav
```

This worked first try. The machinery is all there in the APF bridge module — the `target_dataslot_*`
registers just need an FSM to drive them.

## 🔴 Trap #1 — "Start failed": a data slot needs a size

The first writes logged **`Target: Start failed`**, repeatedly (and our FSM re-firing on the failure
froze the screen). The log gave it away:

```
Host: Slot says it is 0 bytes
Skipping readback because the slot's reported size ... is 0
```

A data slot's **size** lives in Pocket's data-slot BRAM table. A slot with no file loaded is **0
bytes**, and Pocket refuses to write 128 KB into a 0-byte slot. The cheap fix: **pre-create the file**
at the expected path (`/Saves/<platform>/<Author.Core>/pocketroll.sav`) with the right size (128 KB of
zeros). On boot Pocket loads it → the slot is now 131072 bytes → the write starts.

```
File: Load 0x20000000 with 0x0000020000 bytes from slot [PocketRoll]
Host: Updating core data slot BRAM table. Slot ID [48] ... size 131072 bytes
```

(The "proper" alternative is for the core to write the slot's size into the datatable itself before
issuing the command. Pre-creating the file is the one-liner.)

## 🔴 Trap #2 — reading RAM *while the core runs* freezes it (and reads garbage)

With the size fixed, the write started — but pressing our trigger button **froze the camera**, and the
resulting `.sav` was garbage: **every 4 KB block identical**, no `"Magic"` marker, an empty directory.

The cause: we pointed `bridgeaddr` at `0x20000000`, which is served by the stock **`save_handler`**
(its `data_unloader`). That path is designed for the **Pocket-coordinated save** (which happens with
the core quiescent). Hammering it with on-demand reads **while the camera is actively using the same
RAM** both corrupts the read and wedges the core. Lesson: **the stock save read path is not a
random-access window you can poke mid-game.**

## 🔴 Trap #3 — the native save-on-exit: no freeze, still garbage

So we stopped poking it at runtime and let Pocket do its **normal save on exit** instead (give the slot
its own filename so it isn't "cloned from slot 0" and skipped in play-cartridge mode — that
[parameters bit](https://www.analogue.co/developer/docs/overview) was why physical-cartridge saves were
being skipped). The save fired cleanly, no freeze:

```
Slot: Readback from slot ID [48]: 0x20000000 - 131072 bytes
```

…but the content was **the same garbage**. So it was never a runtime-timing problem — the bytes
themselves were wrong.

## 🔬 The marker test that ended it

To find out *where* the bytes came from, we filled `pocketroll.sav` with a known pattern (**`0xAA`**),
let Pocket load it into the core's RAM at boot, took photos, and dumped. If the dump came back `0xAA`,
the mirror wasn't capturing; if `0xAA` + photos, it worked; if neither, the read path was broken.

Result: **zero bytes of `0xAA`** survived, the dump was 98.6% `0xFF`, and **offset `0x0000` equalled
`0x2000`** — i.e. it **aliased at the 8 KB bank boundary**. Verdict: the home-made **write-mirror**
(keeping the internal mapper live to shadow the camera's writes) had **broken bank addressing**
(everything collapsing onto bank 0) **and** the load/read round-trip didn't preserve the RAM. Too many
compounding bugs in an intermediary we didn't need.

## ✅ The answer: read the physical cartridge directly

The internal mirror was always a bolted-on middleman. The **source of truth** is the **cartridge's own
SRAM** — the one the camera already reads and writes perfectly, with a valid `"Magic"`, directory and
photos. So the dump should **bus-master the physical cartridge**: on trigger, pause the emulated CPU,
have the core drive the cartridge bus to read all 128 KB itself, store it in a clean buffer, and expose
*that* buffer to `target_dataslot_write`.

This sidesteps the entire mess — no mirror, no banking bugs, no `save_handler` quirks — and yields a
`.sav` byte-identical to the cartridge, which [MugDump](../../MugDump) turns into PNGs. Bonus: the same
"core drives the cartridge bus" capability is exactly what brick (2), the **reset**, needs to free the
film. That's the next chapter.

---

## 🔄 Plot twist: the bus-master was *also* a trap — and the one-line bug that fooled us for days

Reading the cartridge directly (bus-master) sounded right. It wasn't — not by hand. The Game Boy
cartridge bus is **paced by the CPU's read/write cycle**, with edge-triggered writes and the read
latched at a precise instant (you can see it in the GB core: `cart_di` is valid only when
`cart_sel & cart_oe`). Free-running our own PHI-based timing fought us through ~6 builds: garbage
reads, the RAM-enable write not latching, and pausing/resetting the CPU mid-frame **crashing the
camera** (a glitched Nintendo logo — the boot logo check failing).

So we flipped it again — **stop driving the bus; snoop it.** The GB core already reads the SRAM
perfectly (the camera runs!). So we just *watch*: when the core reads cart RAM (`cram_rd & cart_oe`),
the byte is on the bus at the core's own proven timing — copy it into a buffer. No bus-mastering, no
pause, no crash. As the camera shows the gallery, it reads the directory + thumbnails → we capture
them.

**But here's the part that cost us days.** Every dump — mirror, bus-master, snoop — came back as the
*same* garbage. Different mechanisms, identical bad output. That's impossible… unless they were all
**reading the same wrong place.** The debug log finally showed it:

```
Target: Write from BRIDGE 0x30000000 ... len 0x2000      ← our dump (our buffer) — fine!
Slot:   Readback from slot ID [48]: 0x20000000 - 131072  ← a SECOND write, the native save
```

Our data-slot was `nonvolatile`, so on every exit/sleep Pocket ran a **native save** that read the
slot's `address` (`0x20000000`, the stock save handler) and **overwrote our file** with 128 KB of
unrelated data. We were never looking at our own dump — we were looking at the native save, every
single time. One line in `data.json` (point the slot `address` at our buffer, `0x30000000`) and
suddenly: **`"Magic"` at `0x10D2`, a real photo directory, valid data.** The snoop had been working
all along.

**Lesson:** when every approach fails *identically*, stop iterating on the approach — you're almost
certainly reading/writing the wrong location. And on Pocket specifically: a `nonvolatile` data slot
will quietly write itself back from its `address` on exit; make sure that's the buffer you think it
is.

## 🏁 The finish line — a full, valid save, by snooping

Bank 0 (the directory) proved the snoop. The photos live in banks 1–15 — 128 KB total — and a 128 KB
buffer **doesn't fit in block RAM** (the M10K blocks are nearly all spoken for, ~100 of them by the
core's own cart RAM). The way out: the Pocket has an **unused 128 KB external SRAM** (`sram_*`, you'll
see its pins "stuck at GND" in the fitter report). Use *that* as the snoop buffer — a tiny async
controller, write-on-snoop, read-on-dump, no block RAM at all.

Wire it up, browse the gallery so the camera reads every photo, exit (the native save now reads our
buffer), and:

```
$ node tools/gbcam-sav.js info pocketroll.sav
Active photos : 15 / 30
Stored  checksum : sum=0x89 xor=0xE5
Computed checksum: sum=0x89 xor=0xE5
Checksum OK   : YES ✅
```

A **byte-valid Game Boy Camera save**, checksum-perfect, straight off the Pocket — and
[MugDump](../../MugDump) turns it into PNGs of your actual photos. **No PC in the field. The dream,
done — by *watching* the camera instead of fighting it.**

One honest caveat: the snoop only captures **what the camera reads**, so a photo you merely scroll
past in the grid (thumbnail only) comes out noisy — **open each photo full-screen** before exiting for
a complete 15/15. (A self-driving "read every bank" pass is future work.)

## 🧰 Cheat sheet — writing files to SD from a core

- **`target_dataslot_write` (cmd `0x0184`) works** and is the way to write a file on demand. Drive the
  `target_dataslot_{id,bridgeaddr,length}` regs and pulse `write`, wait `ack` then `done`.
- **A writable slot needs a non-zero size** or the write `Start fail`s. Ship/pre-create the file at its
  size, or write the slot size into the datatable yourself.
- **Give core-output slots their own `filename`** in data.json (`parameters` without the "clone from
  slot 0" bit), or they get skipped in play-cartridge mode.
- **Don't read the stock save region (`0x2xxxxxxx`/`save_handler`) at random mid-game.** It's for the
  coordinated save, not arbitrary access — you'll get garbage and can wedge the core.
- **Use a known-marker file (`0xAA`) to tell a capture bug from a read bug.** Best ten-minute test we
  ran — no recompile, and it ended a day of guessing.
- **If you need the cartridge's real RAM, read the cartridge** — not a shadow copy. Middlemen add bugs.
