# PocketRoll — state & roadmap (onboarding brief)

*A self-contained brief to resume work in a fresh conversation. Captures the dream, what works, the one
open problem (the film reset), everything we tried, the research that reframed it, and the exact next
steps — plus the reference facts (files, signals, save format, build/flash/test, commits, constraints).*

---

## 0. TL;DR

A Game Boy Camera cartridge runs **physically** (passthrough) on the Analogue Pocket via our custom
openFPGA core (fork of budude2/openfpga-GBC). **The DUMP is fully solved and fluid:** the core mirrors
the camera's cart-RAM reads into the gb's internal CRAM block RAM, so a **native Pocket savestate
(Analogue + Up)** serialises the 128 KB cart RAM to a `.sta`; **MugDump reads `.sta` natively** and
turns it into PNGs. **L1 auto-browses** (injects "Right") so the camera reads every photo itself — no
manual scrolling. **Zero freeze, zero relaunch, no PC in the field.**

**The ONE unsolved problem: resetting the film** (blanking the cartridge directory so the camera can
shoot a fresh 30). Every direct attempt freezes the gb or is blocked by the camera's checksum/suicide
logic. **The reframe (from research): don't reset — patch the ROM so the camera OVERWRITES.** Next step
is reverse-engineering the GB Camera ROM's "find a free slot / film full" routine to patch it.

---

## 1. The dream

Walk around with **just the Analogue Pocket + the Game Boy Camera cartridge + an SD card** (no PC in
the field), shoot **forever**, and have every photo land on the SD. At home, convert to PNG with
[MugDump](../../MugDump). Document the whole thing publicly, in English, fun + technical.

---

## 2. What WORKS today (the fluid dump) ✅

Field flow, fully validated on hardware:

```
shoot → open the 1st photo full-screen → L1 (camera auto-scrolls every photo ~8 s)
      → savestate (Analogue + Up)  → keep shooting
home  → drag the .sta into MugDump → PNGs
```

How it works:

- **The mirror** (`src/gb/cart.v`): while playing a physical cart, every byte the gb *reads* from cart
  RAM is also written into the gb's internal CRAM block RAM:
  ```verilog
  wire pr_mirror_we = cart_physical_mode & ce_cpu & cram_rd & cart_oe;
  assign cram_wr = sleep_savestate ? Savestate_CRAMRWrEn : pr_mirror_we | mbc_cram_wr | (cart_wr & is_cram_addr & mbc_ram_enable);
  wire [7:0] cram_di = sleep_savestate ? Savestate_CRAMWriteData : pr_mirror_we ? pr_phys_data : mbc_cram_wr ? mbc_cram_wr_do : cart_di;
  ```
  `pr_phys_data` = `cart_tran_bank1` (the physical read byte), passed in from `core_top` to `cart_top`.
  This matters because the camera's photos are written long ago by the *sensor hardware off the CPU
  bus*, so the gb's normal write-mirror never sees them — only its *reads* do.
- **Full 128 KB capture** (`core_top`): in physical mode the ROM header isn't loaded, so `cart_ram_size`
  was mis-detected and the savestate grabbed only a slice. Forced 128 KB:
  ```verilog
  wire [7:0] cart_ram_size = cart_physical_mode ? 8'd4 : cart_ram_size_raw; // 128 KB → .sta grows 103→234 KB
  ```
- **The savestate is the SD writer.** The Pocket's native savestate cleanly pauses/resumes the gb
  (`sleep_savestate`) and serialises the CRAM block RAM to a `.sta` on SD — fluid, the camera survives.
  This was THE breakthrough (Guillain's "do it like save states"): the gb survives the savestate's
  clean pause but **no other interruption** (see §4).
- **Auto-browse** (`core_top`): the mirror only sees what the camera *reads*, so on **L1** an FSM
  injects "Right" into the gb joypad (`joystick_0[0]`, synced clk_74a→clk_sys). From the full-screen
  photo view that flips through every photo → the camera reads them all → the mirror fills. **Use L1,
  not R1 — R1 is the core's fast-forward and races the camera to a white-screen.**
- **MugDump `.sta` support** (`MugDump/main.js` `coerceGbCamSave`): finds the GB Camera management
  block in the `.sta` — the "Magic" string appearing twice 0xFE apart (echo at cart-RAM 0x10D2,
  primary at 0x11D0) — and slices 128 KB from the cart-RAM base. Accepts `.sta` via drag-drop + dialog.

---

## 3. The ONE open problem: resetting the film

When 30 slots are used the camera is "full" and refuses to shoot. To keep going we must **blank the
physical cartridge's directory** (free the slots). This is the only thing left for the infinite roll.

The directory format (cart RAM): a **30-byte vector at 0x11B2** (`0x00–0x1D` = image number, `0xFF` =
free). The camera writes a new photo to the **lowest-address `0xFF` slot**; when none are `0xFF`, it's
"full". Protected by a 2-byte checksum at 0x11D5/0x11D6 (seeds sum=0x2F, xor=0x15), with an echo at
0x11D7 and a "Magic" marker at 0x11D0. A second management block sits at 0x1000 (Magic at 0x10D2).

---

## 4. Reset attempts — all dead ends (and why)

- **Bus-master write the blank directory** (commit a74fa1d, "L1 reset"): WORKS (writes 0xFF×30 +
  checksum 0x11/0x15) but **freezes the gb** (it tolerates no bus disruption) → needs a relaunch.
- **The gb tolerates NO interruption — proven 4 ways**, all freeze: gate `ce`; restore the cart bank;
  stall via `WAIT_n`; fire `target_dataslot_write` mid-play. Only the *native savestate* pause survives.
- **Reset riding the savestate** (2026-06-27, reverted): trigger the bus-master write during
  `sleep_savestate` (the cart bus is free then — the savestate reads the internal mirror). On hardware:
  **the cartridge was NOT blanked AND the 2nd savestate crashed the gb.** Running bus-master + savestate
  at once collides. Trigger removed from `BM_IDLE` (see the comment there; `sleep_prev` left, inert).
- **Editing the save to fake a free slot: BLOCKED.** Per the save-format RE (see §5): wrong checksum OR
  missing "Magic" → **the camera erases the whole save at reboot (suicide code)**. So you cannot lie
  about free slots from the RAM side — the overwrite must come from the ROM.

---

## 5. The research that reframes it (2026-06-27)

Guillain found the TCRF prototype page; digging from there:

- **The "Debagame Tester" prototype overwrites photos with no delete** — and has **no vector and no
  checksum** at all. So "film full → must delete" is **purely retail-ROM software**, not a hardware law.
- **Homebrew ecosystem**: `untoxa/gb-photo` (open-source GB Camera ROM in C/asm, talks to the real
  M64282FP sensor, 240-photo storage, SD-save not implemented, **needs a reflashable cart**);
  reflashable **flashcarts** (`HDR/Gameboy-Camera-Flashcart`, PCBWay/Ko-fi); the landscape list
  `Raphael-Boichot/Awesome-Game-Boy-Camera-and-Game-Boy-Printer-projects`.
- **`Raphael-Boichot/Inject-pictures-in-your-Game-Boy-Camera-saves`** decoded the save format: the
  "full check" is a **vector scan** (no counter); editing the save is blocked by the checksum + suicide
  code; the prototype has no vector. **Conclusion: overwrite must be a ROM change, not a save edit.**

**Key correction to the architecture:** the sensor is **not** the hard part — it *already* talks to the
ROM in passthrough (we take photos now). The only thing to change is the ROM's photo-management logic.

---

## 6. The decided path forward

| Goal | Approach |
|---|---|
| **Simple reset NOW** (accepts one relaunch) | **Corrupt 1 byte** (the checksum) on the physical cart via a bus-master write → the camera **suicide-wipes** the whole roll on the next reboot. 1 byte vs 74; still freezes + needs a relaunch, but minimal & reliable. |
| **🏆 Grail: ∞ with no reset, 100% software** | **Patch the ROM's "find a free slot / film full" routine** so it cycles 0→29 and overwrites instead of refusing. Keep everything physical (sensor, RAM, ROM); the core just **overlays a few patched bytes on ROM reads** at specific (bank, offset) addresses — same mechanism as the bank snoop we already do. No flashcart. |

Why the patch is small in the core: we already read the physical ROM in passthrough and already snoop
bank writes. The overlay = "for these few ROM addresses, return our bytes instead of the physical one."

---

## 7. Concrete NEXT STEPS

1. **Find the routine to patch.** Locate, in a GB Camera ROM **disassembly**, the code that (a) scans
   the 0x11B2 vector for the lowest `0xFF` slot and (b) refuses when none is free. Identify the exact
   (ROM bank, offset) and the byte change that forces a cycling target slot (overwrite). The RE
   community has worked on this ROM — start there (Boichot's repos, gbdev, any GB Camera disassembly).
2. **Implement the ROM patch overlay in `core_top`/`cart.v`**: track the ROM bank (snoop 0x2000–0x3FFF
   writes, like we do for RAM banks); for ROM reads at the patch (bank, offset), return the patched
   byte instead of `cart_tran_bank1`. Tiny, self-contained.
3. **Test**: shoot >30 → confirm the camera keeps shooting (overwriting) with no "full" → savestate per
   batch of 30 → MugDump. No reset, no relaunch.
4. **Fallback in parallel**: if the patch RE stalls, ship the 1-byte suicide-wipe reset (simple,
   relaunch-based) so the loop is at least complete.
5. **Cleanup**: the bus-master FSM (`BM_*`), the external-SRAM snoop path, and the data.json slot-48
   exit-save are now **superseded by the savestate dump** — keep or prune as the patch work settles.

---

## 8. Reference

**Architecture.** Physical GB Camera cartridge in passthrough. Core = fork of budude2/openfpga-GBC.
`core_top.sv` instantiates the `gb` (CPU/PPU) and `cart_top` (cart.v, the mapper) separately and wires
them. `cart_do = cart_physical_mode ? cart_tran_bank1 : cart_do_backend`. The gb's joypad is
`joystick_0` → SGB → `joy_din`.

**Key files / signals.**
- `src/gb/cart.v` — mapper; the CRAM block RAM (`dpram cram_l`/`cram_h`, 2×64K×8 = 128 KB); the mirror
  (`pr_mirror_we`, `pr_phys_data`); the savestate CRAM port (`Savestate_CRAMAddr/RWrEn/WriteData/ReadData`,
  gated by `sleep_savestate`); `pr_cram_addr` exposed for the (legacy) snoop.
- `src/core/core_top.sv` — `pr_phys_data(cart_tran_bank1)` to cart_top; `cart_ram_size` force; the
  auto-browse FSM (`pr_inject_right`, `joystick_0[0] | pr_right_inj`, L1 = `cont1_key[8]`); the
  bus-master FSM (`BM_*`, `pr_busmaster` mux, `pr_wait`→`cart_wait_n`) now mostly idle; the savestate
  glue (`save_state_controller`, `ss_save`, `sleep_savestate`, `savestate_size`); fast-forward
  `ff_en & cont1_key_s[9]` (R1 — keep clear of it).
- `MugDump/main.js` — `coerceGbCamSave` (`.sta` → 128 KB cart RAM via the Magic-pair locate).
- `pkg/gb/Cores/Guillain-RDCDE.GBCamera/data.json` — slot 48 "PocketRoll" (pocketroll.sav, address
  0x30000000); the legacy exit-save path (superseded by the savestate).

**GB Camera save format.** Vector 0x11B2 (30 bytes, value=image#, 0xFF=free, written lowest-first).
Magic at 0x11D0 (`4D 61 67 69 63`) and echo Magic at 0x10D2. Checksum 0x11D5 (sum, seed 0x2F) / 0x11D6
(xor, seed 0x15) over 0x11B2–0x11CF. Echo of 0x11B2–0x11D6 at 0x11D7. Second block at 0x1000–0x11B1
(scores), Magic 0x10D2. **Wrong checksum or missing Magic → full-save wipe on reboot.** Tools:
`pocketroll/tools/gbcam-sav.js` (info/verify/free), `find-sram-in-sta.js`.

**Build / flash / test.**
- Compile in Quartus 25.1 → `src/output_files/ap_core.rbf` (check `ap_core.flow.rpt` "Flow Status:
  Successful"; the `.rbf` timestamp/size confirms a fresh build — Pocket RTC vs PC clock can mislead,
  trust size/Flow-Status).
- Reverse: `node pocketroll/core/reverse_rbf.js ap_core.rbf bitstream.rbf_r`.
- Flash: copy `bitstream.rbf_r` → `<SD>\Cores\Guillain-RDCDE.GBCAM\gb.rbf_r` (SD usually `E:`; auto-find
  by the `Cores\Guillain-RDCDE.GBCAM` folder — it may vanish when the card is in the Pocket).
- Savestate trigger on Pocket: **Analogue + Up**. Savestates land in
  `<SD>\Memories\Save States\Guillain-RDCDE.GBCAM\*.sta` (~234 KB). Logs in `<SD>\System\Logs\`.

**Milestone commits (PocketRoll, branch master).** ce1fc12 snoop · 88ac395 full snoop dump (ext SRAM)
· c678743 one-button bus-master dump (sample at ce_cpu) · a74fa1d infinite cycle (pause + L1 bus-master
reset) · c1d02a3 fluid savestate dump (mirror + cart_ram_size) · 0986332 auto-browse (L1 injects Right).
MugDump: 99942fe `.sta` support.

**Constraints / operating rules.**
- **No JTAG, never open/buy the Pocket.** Debug via Pocket Debug Logging (`/System/Logs/`), bridge
  probes, marker files. (A reflashable *cartridge* is separate hardware; Guillain prefers software-only.)
- Commit identity **Guillain-RDCDE**, **zero Claude attribution**, push direct to master, selective
  `git add`. **Never commit personal photo files** (`*.sav`/`*.sta` with real photos — gitignored).
- Respond in **French**.
- Docs 06 (build war story) · 07 (dump saga) · 08 (infinite roll) · 09 (fluid savestate dump) · 10 (this).
