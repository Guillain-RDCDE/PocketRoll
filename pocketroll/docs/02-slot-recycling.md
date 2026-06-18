# Step 2 — Proving slot recycling (in software)

> Turn Step 1's theory into runnable code, and validate the "free a slot" recipe where one iteration
> costs 2 seconds — **before** any Verilog.

---

## 🟢 In plain English

We wrote a little program (`tools/gbcam-sav.js`) that can open a Game Boy Camera save, list the
photos, and above all **mark a photo as "deleted"** exactly the way the camera would — by ticking
the box in the directory **and** recomputing the check value so the cartridge doesn't notice a thing.

If we can do this in a loop without ever corrupting the save, then the project's core idea (recycling
the 30 slots forever) holds up.

## 🔴 The tool

`tools/gbcam-sav.js` — Node, zero dependencies, also reusable as a module inside MugDump.

```bash
node tools/gbcam-sav.js info   <in.sav>                       # state + stored vs computed checksum
node tools/gbcam-sav.js verify <in.sav>                       # does our model match the cartridge?
node tools/gbcam-sav.js free   <in.sav> <galleryPos> -o out.sav   # free a slot
node tools/gbcam-sav.js free   <in.sav> --slot <N>     -o out.sav
```

`free` applies the [Step 1](01-game-boy-camera-sram-format.md) recipe:
1. directory entry `0x11B2+i` → `0xFF`; 2. recompute checksum `0x11D5/0x11D6`;
3. copy the echo at `0x11D7`. **The image is not erased** (it's meant to already be on the SD).

## Validation: against the camera's ground truth ✅

Rather than an indirect hardware test, we compared our recipe to **two real saves** produced by the
console: `before-del` (2 photos) and `after-del` (1 photo, **deleted by the camera itself**).

- Our `free --slot 1` on `before-del` reproduces the camera's deletion to within **6 bytes out of
  131072**; the core (state vector + checksum `0x11D5` + echo) is **byte-perfect**.
- Those 6 bytes form a **second management block** ("minigame/animation") at `0x1000` (stored twice,
  primary + echo at `+0xD9`), with **its own checksum** `0x10D7-0x10D8` — which we also cracked:
  range `0x1000..0x10D1`, **same seeds `0x2F`/`0x15`** as the directory.
- The byte that changes there (`0x10BD`: `0x89→0x90`) is **animation state** (the two snapshots were
  taken at different moments), **not** deletion-related. Our recipe doesn't touch it → the forged
  save stays **valid and self-consistent**.

**Conclusion: the recipe is functionally complete and exact.** The 6-byte diff is timing noise, not
a defect. The camera itself validates our science.

### Internal-consistency self-test

```bash
node tools/selftest.js   # 11 assertions OK, including the 30-slot loop
```

The self-test builds a synthetic save **with our own model**: it validates the plumbing (free →
checksum → echo → re-verify, including freeing all 30 slots one by one). The checksum *model* itself
is confirmed by the ground-truth comparison above on real Analogue Pocket saves.

### How the model was confirmed

On a real save (`samples/real-pocket.sav`, dumped from a cartridge via the Analogue Pocket,
2 photos), reverse engineering (`tools/reverse-checksum.js`) revealed:

- checksum computed **over the directory only** `0x11B2..0x11CF`;
- **sum initialized to `0x2F`**, **XOR initialized to `0x15`**;
- the `"Magic"` string (`0x11D0`) is a literal marker, **outside the computation**.

After fixing `computeChecksum()`, `verify` reproduces the stored checksum byte for byte, and a `free`
followed by a `verify` stays ✅: we know how to forge a modified save the camera considers healthy.

### Note on the ".sta save state" route (dead end, by choice)

Loading an edited `.sta` on the Pocket fails ("loading fail"). Diffing two real `.sta` files shows
the **header is identical regardless of content** (the `0x18` field is a constant cartridge hash,
not a checksum). The blocking validation is therefore at the **payload** level, buried in snapshot
noise — unsolved, and of little value (the test would only yield a "frozen moment"). We stop there:
the ground-truth comparison against the camera above is stronger.
