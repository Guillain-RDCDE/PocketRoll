# The Game Boy Camera saves, explained (on Analogue Pocket)

*Or: everything we learned hacking apart `.sav` and `.sta` files, so the next person who types
"Game Boy Camera save format" or "Analogue Pocket .sta loading fail" at 2 a.m. finally lands on some
answers.*

> TL;DR — The Game Boy Camera stores 30 photos in 128 KB of SRAM, with a little "directory" and some
> checksums you can recompute (and the docs floating around online get the seeds wrong: it's **`0x2F`
> for the sum, `0x15` for the XOR**). The Analogue Pocket's `.sta` save states are a container whose
> header we decoded, but which refuses to load if you tamper with the SRAM inside it ("loading
> fail"). Details below, from gentle to gnarly.

---

## 🟢 For normal humans

### What's the problem again?

The **Game Boy Camera** (1998, the crummiest camera ever to make millions of people smile) stores
**30 photos**, period. Not 31. The room is etched into a small memory on the cartridge: **128
kilobytes**. When it's full, it's full.

On the **Analogue Pocket**, you can back game state up to the SD card via **Memories**. For the Game
Boy Camera, that means you can grab a file containing your 30 photos, and — here's where it gets fun
— **mess with it**.

### The two files to know

When you make a Memory on the Pocket, you get **two** twin files:

- a **`.sav`** (128 KB): the exact photocopy of the cartridge memory. That's *your photos*.
- a **`.sta`** (~197 KB): the **save state**, a snapshot of the whole console at one exact moment
  (the screen, the RAM, everything). That's what you "load" to resume right where you were.

Remember mainly: the `.sav` is your photos; the `.sta` is "the console frozen in time."

### The fun bit: deleting ≠ erasing

When you "delete" a photo on the Game Boy Camera, **the image stays put**. The camera merely ticks
*"this slot is free"* in a little list. That's why people have **recovered "deleted" photos** years
later. And it's also why we can, in theory, tell the camera *"this slot is free"* ourselves to make
room — endlessly.

### And the infamous "loading fail"?

If you copy a Memory by hand onto the SD, **the Pocket loads it just fine** (tested). But if you
**modify** the `.sta` by even a single byte inside, it refuses: **"loading fail"**. The save state
has an internal safeguard. So: copying/renaming a `.sta`, yes; tampering with it, no. To mess with
your photos, aim at the **`.sav`** (and a PC emulator to read it back), not the `.sta`.

---

## 🔴 For those who want the bytes

Everything below is **verified on real saves** dumped from an Analogue Pocket (US/EU Game Boy Camera
cartridge, serial `C54AC95A`). Offsets are absolute within the file.

### A. The Game Boy Camera `.sav` (128 KB SRAM)

```
0x00000        header / management area (bank 0)
0x02000+i*0x1000   photo i  (30 slots of 4096 B: image 0xE00 + thumbnail + metadata 0xF00)
0x20000        end
```

#### The photo directory ("state vector")

| Offset | Size | Role |
|---|---|---|
| `0x11B2`–`0x11CF` | 30 B | gallery order. Each byte = slot number (`0x00`–`0x1D`), `0xFF` = **empty/deleted** |
| `0x11D0`–`0x11D4` | 5 B | the literal string `"Magic"` (`4D 61 67 69 63`) — just a marker |
| `0x11D5`/`0x11D6` | 2 B | **checksum** of the directory (sum / XOR) |
| `0x11D7`–`0x11FB` | 37 B | **echo** (backup copy of `0x11B2`–`0x11D6`) |

Deleting a photo = set its entry to `0xFF`, recompute the checksum, copy the echo. The image is never
touched.

#### The checksum, for real (⚠️ the online docs are wrong)

Several sources repeat a seed "`Magic` + `0x2F` + `0x15`" over the range `0x11B2`–`0x11D4`. **Wrong**,
at least on the standard ROM. What reproduces the stored bytes on real saves:

```python
# directory checksum — covers the DIRECTORY ONLY (Magic excluded)
csum = 0x2F            # sum seed
cxor = 0x15            # xor seed
for b in sram[0x11B2 : 0x11D0]:   # 0x11B2..0x11CF inclusive
    csum = (csum + b) & 0xFF
    cxor = (cxor ^ b) & 0xFF
sram[0x11D5] = csum
sram[0x11D6] = cxor
# then copy 0x11B2..0x11D6 -> 0x11D7 (the echo)
```

"Magic" lives in the *file* at `0x11D0`, not in the *computation*. Proof: on a 2-photo save, the raw
sum of the directory is `0xE5` and the stored byte `0x14` → seed `0x14 − 0xE5 = 0x2F`. The raw XOR is
`0x01` → seed `0x01 ^ 0x14 = 0x15`. QED.

#### Bonus: there's a *second* block using the same routine

Comparing a "2 photos" save and the same one after a camera-side deletion, we find a second
management block ("minigame/animation" area) built **exactly the same way**:

```
0x1000..0x10D1   data
0x10D2..0x10D6   "Magic"
0x10D7/0x10D8    checksum (same seeds 0x2F / 0x15, range 0x1000..0x10D1)
+0xD9            … and this whole block is duplicated as an echo (checksum at 0x11B0/0x11B1)
```

In other words, the Game Boy Camera reuses **the same little checksum routine** all over, with seeds
`0x2F`/`0x15`. Handy to know if you're forging saves.

#### Ground truth

Reproducing a deletion programmatically yields a `.sav` **identical to within 6 bytes out of 131072**
to what the camera produces itself — and those 6 bytes are just animation state (two snapshots taken
at different moments), not the deletion. The photo core is **byte-perfect**.

### B. The Analogue Pocket `.sta` save state

A format **undocumented anywhere else** as far as we know (the only public tool,
[pokepocket-save-recovery](https://github.com/Galkon/pokepocket-save-recovery), only *extracts* the
save block, it never writes). Here's the header, decoded:

```
0x00  01 'S' 'P' 'A'      magic  (bytes 01 53 50 41)
0x04  uint32 LE           section pointer
0x08  uint32 LE           = sram_offset + 0x20000  (end of the SRAM block)
0x0C  uint32 LE = 1       \ counters
0x10  uint32 LE = 2       /
0x14  uint32 LE           cartridge identification CRC (= the ...C54AC95A... in the filename)
0x18  uint32 LE           CONSTANT 32-bit hash (tied to the cartridge/core, NOT the saved content)
0x1C  "Game Boy Camera\0" game name
…
????  128 KB SRAM block   (uncompressed, byte-for-byte identical to the .sav)
…
end   padding 00 00 00 FF
```

To **locate the SRAM** reliably inside the `.sta`: search for the **74-byte signature** of the
management area (`sav[0x11B2 : 0x11FC]`) — definitely **not** the "Magic" string alone, which appears
several times (directory, echo, WRAM copies) and will land you at the wrong offset.

#### Why an edited `.sta` triggers "loading fail"

We diffed a "2 photos" `.sta` and a "1 photo" `.sta`: **the header is exactly identical regardless of
content** (including `0x18`). So the `0x18` field is *not* a content checksum — it's a constant
cartridge hash. The validation that blocks a modified `.sta` therefore lives in the **payload**
(probably a per-data-slot check), buried in the noise of two snapshots taken at different moments — we
didn't isolate it.

**The practical verdict**: don't edit the SRAM *inside* a `.sta`. The Pocket also can't write a `.sav`
back into a physical cartridge (Memories are a **one-way** backup). To experiment on your photos, edit
the **`.sav`** and read it back in a **PC emulator** with camera support (SameBoy, BGB). And to write
into the real cartridge, you need hardware like a **GBxCart RW**.

---

## In short

- Your photos live in the `.sav` (128 KB); the `.sta` is a console snapshot.
- The Game Boy Camera directory checksum: seeds **`0x2F` / `0x15`**, over `0x11B2..0x11CF`.
  (And the same routine is reused elsewhere in the save.)
- Deleting = tick `0xFF` + recompute the checksum + copy the echo. The image stays.
- A `.sta` can be copied/renamed freely, but **not** tampered with ("loading fail").
- The Pocket doesn't re-inject a `.sav` into a cartridge: Memories = one-way backup.

*All of this was verified by hand on real saves. If you spot a difference on another ROM revision
(Japanese Pocket Camera, Hello Kitty…), the seeds or offsets may move — diff two successive saves,
it's the best teacher.*
