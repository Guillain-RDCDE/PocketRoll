# Step 1 — The Game Boy Camera SRAM format

> The foundation stone of the project. Before any Verilog, we need to know **where a photo lives**
> in the cartridge memory, and above all **how to tell the camera a slot is free**. That single
> manipulation is what makes the roll infinite.

---

## 🟢 In plain English

The Game Boy Camera stores its photos in a small memory on the cartridge: **128 KB**, exactly
enough room for **30 photos**. When you "delete" a photo, the camera **doesn't erase the image**:
it merely ticks *"this slot is empty"* in a little **list** (a table of contents). The image stays
there until a new one overwrites it.

Our plan exploits exactly this: as soon as a photo is taken, we **copy it to the SD card**, then
**tick "empty slot"** in that table — without brutally erasing anything. The camera then sees a free
spot and accepts the next photo. Forever.

So the camera doesn't scream "save corrupted," there's a catch: next to the table sits a **check
value** (a checksum). If we change the table without recomputing it, the camera rejects everything.
The whole subtlety of Step 1 is right there: **cleanly editing the table AND its check value.**

---

## 🔴 Full structure (for the geeks)

### Macro view

The SRAM is **131,072 bytes** (128 KB) = **16 banks of 8 KB** (the `0xA000–0xBFFF` window on the
Game Boy side; in the `.sav` file it's a flat blob from 0x00000 to 0x1FFFF).

```
0x00000 ┌───────────────────────────────┐
        │  header / management area       │  bank 0 (8 KB)
        │  game state, thumbnails,         │  → holds the DIRECTORY (state vector)
        │  photo directory, checksums      │
0x02000 ├───────────────────────────────┤
        │  Photo 0   (0x1000 slot)        │
0x03000 ├───────────────────────────────┤
        │  Photo 1                         │
        │  …                               │
        │  Photo 29                        │
0x20000 └───────────────────────────────┘  end (= 0x2000 + 30 × 0x1000)
```

> Arithmetic check: `0x2000 (header) + 30 × 0x1000 (photos) = 0x20000 = 131,072`. ✓

### Anatomy of a photo slot (`0x1000` = 4096 bytes)

Photo `i` starts at **`0x2000 + i × 0x1000`**.

| Component | Offset (relative to slot) | Size | Contents |
|---|---|---|---|
| Main image | `0x000` | 3584 B (`0xE00`) | 128×112 px, **224 tiles** of 16 B (2bpp) |
| Thumbnail | ≈ `0xE00` | ~256 B | gallery thumbnail |
| Metadata | `0xF00` | 256 B | camera settings, owner ID, comment… |

> ⚠️ **A source discrepancy to settle empirically.** MugDump's decoder
> (`renderer/js/gbcam.js`) puts the image/thumbnail boundary at `0xE00` (3584 = exactly 224 tiles).
> R. Boichot's docs list image `0x000–0xDEF` then thumbnail `0xDF0–0xEFF`. The gap is tiny but real;
> we **settle it by diffing two real saves** (see below). To *read* an image, MugDump's version is
> enough; for our project, only the **management area** below truly matters.

---

## 🎯 The management area — the heart of the project

This is what MugDump **doesn't use** (it guesses full slots with a heuristic) and what **we must
rewrite** to recycle a slot. Verified offsets (standard ROM):

| Element | Offset | Size | Role |
|---|---|---|---|
| **Directory** (*state vector*) | `0x011B2`–`0x011CF` | 30 B | gallery order. Each byte = slot number (`0x00`–`0x1D`), or **`0xFF` = empty/deleted** |
| **Marker** `"Magic"` | `0x011D0`–`0x011D4` | 5 B | literal string `4D 61 67 69 63` — **outside the checksum** (just a sentinel) |
| **Checksum** of the directory | `0x011D5`–`0x011D6` | 2 B | protects **the directory only** (`0x011B2`–`0x011CF`) |
| **Echo** (backup copy) | `0x011D7`–`0x011FB` | 37 B | mirror of `0x011B2`–`0x011D6` (directory + Magic + checksum) |

> 💡 **Verified on a real Analogue Pocket save** (`samples/real-pocket.sav`). Raw dump of the area:
> `00 01 FF…FF` (directory, 2 photos) · `4D 61 67 69 63` ("Magic") · `14 14` (checksum) · then the
> echo. The `DB 33` bytes just before (`0x11B0`) belong to another structure (out of scope here).

**Reading the directory.** The `n`-th byte from `0x11B2` gives the slot shown at gallery position
`n`. Value `v` → image stored at `0x2000 + v × 0x1000`. The value `0xFF` marks an **unused** slot:
the camera skips it in the viewer **and treats it as reusable**.

**Deleting = not erasing.** Deleting a photo erases no image bytes: the camera just sets its entry
to `0xFF` in the directory. That's exactly the gesture we'll automate.

### Checksum algorithm (reverse-engineered, confirmed)

```text
Range covered : the DIRECTORY ONLY, bytes 0x011B2 … 0x011CF inclusive (30 bytes)
Seeds         : sum initialized to 0x2F ; xor initialized to 0x15
                (the "Magic" string at 0x011D0 is NOT summed — it's a marker)

sum = 0x2F ; xor = 0x15
for each byte b in 0x011B2 … 0x011CF :
    sum = (sum + b) & 0xFF
    xor = (xor ^ b) & 0xFF

write at 0x011D5 = sum   (left byte)
write at 0x011D6 = xor   (right byte)
```

> These two seeds `0x2F`/`0x15` aren't guessed: on the real save, the raw sum of the directory is
> `0xE5` and the stored checksum `0x14` → seed `0x14 − 0xE5 = 0x2F`; the raw XOR is `0x01` → seed
> `0x01 ^ 0x14 = 0x15`. The tool `tools/gbcam-sav.js verify` confirms it.

### 🧰 Recipe: "free a photo's slot" (the project's key gesture)

```text
1. (the image must already be exported to SD)
2. Find in 0x011B2..0x011CF the byte pointing at the photo (its value = slot number)
3. Set it to 0xFF  (and, if desired, compact the gallery order)
4. Recompute the checksum 0x011D5..0x011D6 (algorithm above)
5. Copy 0x011B2..0x011D6 to the echo 0x011D7..0x011FB
→ the camera sees a free slot, the SD image is preserved, no corruption.
```

This is the operation [Step 2](02-slot-recycling.md) proves, and [Step 4](05-export-recycling-design.md)
will implement in Verilog (after each detected shot).

---

## ⚠️ Differences across ROM versions

The format isn't universal — to handle if we target several cartridges:

- **Standard Game Boy Camera** (US/EU/Japan): everything above applies.
- **Hello Kitty Pocket Camera**: unprotected save at `0x01000–0x01012`, **no checksum** after
  "Magic", user profile photos at `0x011FC–0x0187B`.
- **Debagame / "Second Impact" tester**: minimal protection, **no state vector**, calibration data
  at `0x01000–0x01FFF`.

> For PocketRoll we target the **standard ROM** first (the project's cartridge:
> `Game Boy Camera (USA, Europe) (SGB Enhanced)`).

---

## 🔬 Verify it yourself (empirical method, free)

No doc beats a binary diff of your own saves:

1. In an emulator with camera support, take **1 photo**, save → `a.sav`.
2. Take **1 more photo**, save → `b.sav`.
3. Binary `diff` `a.sav` vs `b.sav` → you see **exactly** which bytes move on add.
4. **Delete** the 2nd photo in the camera, save → `c.sav`, diff again.
   → you watch the directory entry flip to `0xFF` + the checksum get recomputed live.

This confirms the offsets above **on your exact ROM version** and settles the `0xDEF`/`0xE00`
discrepancy. It's also the perfect test bench to validate our recycling recipe before writing a
single line of Verilog.

---

## What it buys right now

- **For PocketRoll**: the slot-recycling recipe, to port to Verilog (Step 4).
- **For [MugDump](../../MugDump)**: it could read the **real** directory (`0x11B2`) instead of its
  "≥96% identical bytes" heuristic → exact slot detection, correct gallery order, and proper
  handling of deleted-but-not-erased photos.

## Sources

- Raphaël Boichot — [Inject pictures in your Game Boy Camera saves](https://github.com/Raphael-Boichot/Inject-pictures-in-your-Game-Boy-Camera-saves) (format per ROM version)
- insideGadgets — [Learning about Game Boy Camera saves](https://www.insidegadgets.com/2017/07/11/learning-about-gameboy-camera-saves-and-converting-stored-images-to-bitmap/)
- [Pan Docs — Game Boy Camera](https://gbdev.io/pandocs/Gameboy_Camera.html)
- MugDump's decoder: `renderer/js/gbcam.js`
