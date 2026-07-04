# 13 — On-board photo viewer core: design & feasibility

*A companion openFPGA core that reads Game Boy Camera savestates (`.sta`) / saves (`.sav`)
straight off the SD card and displays the photos on the Analogue Pocket's screen — no PC, no
browser. This is the design phase of a hardware project: everything below is grounded in the real
budude2 APF interface (`src/core/core_top.sv`) and the exact GB Camera photo format (from
[`gbcam.js`](https://github.com/Guillain-RDCDE/MugDump/blob/main/docs/js/gbcam.js)), but nothing
here is built or hardware-verified yet. Building it needs the compile → reverse → flash loop, same
as PocketRoll.*

---

## 0. Goal & scope

**v1 goal:** put an SD card with your PocketRoll savestates into the Pocket, launch this core, pick a
`.sta`, and **browse its ~30 photos on screen** with the D-pad. That's the whole "no PC to *look* at
your shots" win the forum thread asked for.

**In scope for v1**
- Load a user-selected `.sta` (or a raw 128 KB `.sav`) from the SD into core memory.
- Locate the Game Boy Camera cart RAM, find the occupied photo slots, decode the selected one.
- Render it to the Pocket screen, scaled and centred, with a small `photo N / M` label.
- Navigate photos with **D-pad ◀ ▶**.

**Out of scope for v1** (later milestones, not the first target)
- PNG export on the device (MugDump already develops `.sta` → PNG; viewing is the v1 want).
- Browsing *across* savestates on screen (APF doesn't hand a core a directory listing cleanly —
  see §5). v1 = "pick a file, view its roll"; re-pick to view another.
- Palettes/filters/effects (that's MugDump's job).

**Reality check.** The Pocket runs only FPGA cores — there is no app runtime — so this is a new,
small Verilog core, and it can only be validated by building and flashing on real hardware. I can
design it, write the HDL, and do the reverse+SD copy; Guillain compiles/flashes/tests; we iterate.

---

## 1. Why this is tractable

It is *far* simpler than PocketRoll. PocketRoll had to be a whole Game Boy with a live physical
cartridge on a running clock. This core is essentially: **load a buffer → decode 2bpp tiles into a
tiny framebuffer → drive a video raster from it.** No CPU, no cartridge bus, no savestates, no
timing-critical passthrough. The two real pieces of plumbing — APF file load and APF video out — are
already solved and visible in budude2's `core_top.sv`; we reuse the same interfaces.

---

## 2. The photo format (exact, from gbcam.js)

Everything is inside a **128 KB cart-RAM image**:

- Photo data starts at **`0x2000`**; slot *i* is at **`0x2000 + i*0x1000`** (30 slots, `0x1000` each).
- The image is the first **`0xE00` (3584)** bytes of the slot = **16 wide × 14 tall tiles**, row-major.
- Each tile is **8×8, 2bpp, 16 bytes**: 8 rows of `[lo, hi]`. For column `col`, `bit = 7 - col`,
  `color = (hi[bit] << 1) | lo[bit]` → **0..3**.
- Photo is **128 × 112** px.
- **Occupancy:** the ROM keeps a 30-byte summary vector at **`0x11B2`** (value = display number,
  `0xFF` = empty). Reading that is cleaner than MugDump's ">96% one byte" heuristic — v1 should use
  the summary vector to know which slots hold a photo and in what order.

All of this is trivial combinational/BRAM logic in Verilog.

## 3. `.sta` vs `.sav`

- A **`.sav`** is exactly the 128 KB cart RAM → base offset 0, done.
- A **`.sta`** (~234 KB Pocket savestate) *contains* the cart RAM somewhere inside. PocketRoll/MugDump
  locate it by the **management-block "Magic" pair** (echo `"Magic"` at cart-RAM `0x10D2`, primary at
  `+0xFE`). Same scan here: walk the loaded buffer for two `"Magic"` markers `0xFE` apart, set the
  cart-RAM base to `marker - 0x10D2`. (This is the exact `coerceGbCamSave` logic, now in hardware: a
  small FSM over the loaded buffer.)

v1 can ship `.sav` first (base 0, no scan) to get pixels on screen fastest, then add the `.sta` scan.

## 4. Architecture

```
  ┌─────────────┐   dataslot    ┌──────────────┐  scan for   ┌───────────────┐
  │ user picks   │  load (host   │  file buffer  │  Magic pair │  cart-RAM base │
  │ .sta on SD   ├──────────────►│ (SDRAM/BRAM)  ├────────────►│  + slot table  │
  └─────────────┘   → bridge     └──────────────┘             └───────┬───────┘
                                                                       │ selected slot
                                        D-pad ◀ ▶ selects photo        ▼
   ┌──────────────┐   read     ┌──────────────────┐  decode   ┌──────────────────┐
   │  video raster │◄──────────┤ 128×112 2bpp      │◄──────────┤ tile decoder FSM  │
   │ video_rgb/... │  per-pixel │ framebuffer (BRAM)│  on select │ (16 B → 8×8 px)   │
   └──────────────┘            └──────────────────┘            └──────────────────┘
```

**4a. File load (APF dataslot → core memory).** budude2 already loads ROM/save this way. In
`core_top.sv` the host writes a loaded file into core memory over the **bridge** (`bridge_addr`,
`casex(bridge_addr)` routing, ~L460) and signals completion with `dataslot_update` /
`dataslot_allcomplete` (L289-293). We declare **one user-selectable data slot** in `data.json` for
the savestate; the host loads the chosen file into a buffer (SDRAM for `.sta`, or BRAM for a 128 KB
`.sav`), and `allcomplete` triggers the parse.

**4b. Locate + index.** On `allcomplete`: (if `.sta`) run the Magic-pair scan FSM to get the base;
read the 30-byte summary vector at `base+0x11B2` into a small slot table (which physical slots are
occupied, and their order). Expose `photo_count`.

**4c. Decode-on-select.** Keep a **current index**. When it changes (D-pad), a tiny FSM walks the
selected slot's `0xE00` image bytes, decodes each 16-byte tile, and writes the 0..3 pixel values into
a **128×112 framebuffer BRAM** (14 336 entries × 2 bits = 3.5 KB — nothing). Decode of one photo is a
few thousand cycles = imperceptible.

**4d. Video raster.** Drive the openFPGA video interface (`video_rgb[23:0]`, `video_rgb_clock`,
`video_de`, `video_hs`, `video_vs`, `video_skip` — all present in `core_top.sv` L155-161). Choose an
output resolution (e.g. 160×144 like the GB, or a clean multiple), center the 128×112 image with an
integer scale, and for each active pixel look up the framebuffer, map 2bpp → a 4-shade palette (DMG
green or grayscale), and drive `video_rgb`. A thin border + a `photo N / M` readout (a tiny built-in
font in BRAM) is the whole UI.

**4e. Input.** Read `cont1_key` (already wired in budude2): **Left/Right** = prev/next photo (wrap),
and reserve **Up/Down** for switching savestates once §5 is solved.

## 5. The one genuine unknown: browsing files on-device

APF cleanly gives a core a **user-selected file** (the core-settings file picker bound to a data
slot) and lets the core **read/write named files** it already knows (`target_dataslot_read/openfile/
getfile`, L323-334). What it does **not** obviously expose is a **directory listing** — a core can't
easily "show me every `.sta` on the card." So:

- **v1 (safe):** the Pocket's own file picker chooses the `.sta`; the core views that roll. To see
  another, open the picker again. This needs no directory enumeration and is fully APF-idiomatic.
- **v2 (stretch):** investigate whether `target_dataslot_getfile`/`openfile` can enumerate a folder
  (the param/response structs at L325-326 are marked "require additional param/resp structs to be
  mapped" — unmapped in budude2). If enumeration is possible, add on-screen savestate browsing
  (Up/Down = previous/next `.sta`). This is the item to research before promising the "infinity of
  savestates, all on device" version.

Being honest: **v1 is confidently doable; the fully-autonomous multi-savestate browser depends on an
APF capability I haven't yet confirmed.**

## 6. Build target & scaffold

Two ways to start the core:
- **A. Strip budude2's core** — keep its proven APF wrapper (video, bridge, dataslot, input,
  clocks/PLLs) and rip out the Game Boy, leaving our loader + decoder + raster. Fastest path to a
  booting core because the hard openFPGA plumbing already works and builds with **Quartus 25.1**.
- **B. Analogue `core-template`** — cleaner slate, but re-derive all the plumbing. More work.

**Recommendation: A.** Fork the PocketRoll tree into a sibling core, gut `src/gb/`, and replace the
video source with our raster. Reuse `reverse_rbf.js`, the SD packaging, and the 25.1 recipe verbatim
(doc 06). Package under a distinct `<author>.<shortname>` (e.g. `Guillain-RDCDE.GBCVIEW`) so it sits
beside PocketRoll on the SD.

**Files the scaffold will add**
- `viewer/core_top.sv` — APF wrapper (from budude2) with the GB removed; wires loader → decoder →
  raster → video.
- `viewer/photo_decoder.v` — tile decoder + framebuffer writer (the §2 spec).
- `viewer/sta_locate.v` — Magic-pair scan FSM (the §3 spec).
- `viewer/video_gen.v` — raster + palette + scale + `photo N/M` overlay.
- `pkg/.../{core.json,data.json,video.json,interact.json}` — one user-selectable savestate slot,
  video mode, palette toggle.

## 7. Milestones (each = one build/flash/test with Guillain)

1. **Boots + loads a file** — core boots (not black), a picked `.sav` lands in the buffer, `photo_count`
   shown as a number on screen. (Proves APF video + dataslot in *our* core.)
2. **One photo on screen** — decode slot 0 → framebuffer → raster. First real pixels.
3. **D-pad navigation** — Left/Right cycles occupied photos, label updates.
4. **`.sta` support** — Magic-pair scan so savestates work directly (not just `.sav`).
5. **Polish** — palette toggle, centering/scale, empty-roll message.
6. *(stretch)* **Multi-savestate browse** — pending the §5 APF enumeration question.

## 8. Constraints (unchanged from PocketRoll)

Quartus 25.1 + `` `define isgbc 0 `` heritage, bit-reversed `gb.rbf_r`, distinct SD folder, no JTAG
(debug via Pocket logs), commit identity **Guillain-RDCDE**, never commit personal `.sta`/`.sav` or
ROMs. Guillain builds/flashes; the assistant designs, writes HDL, and does reverse + SD copy.

---

**Status: scaffold started — decode heart written and simulation-verified.** See
[`../viewer/`](../viewer/): `gbcam_photo_decode.v` (slot → 128×112 framebuffer) and `gbcam_sta_locate.v`
(Magic-pair base scan) are implemented and pass Icarus testbenches against vectors from a reference
model — which is itself cross-checked **pixel-for-pixel against MugDump's `gbcam.js` on a real `.sta`**.
So the bug-prone algorithm (§2/§3) is proven. Still to write in the **hardware phase** (Guillain's
build/flash loop): `video_gen.v`, the budude2-derived `core_top.sv` wrapper, and the packaging — i.e.
milestone 1 onward. v1 (view a roll on the Pocket, no PC) stays a confident, well-scoped target; it
will not be "done tonight," but its riskiest logic is now tested.
