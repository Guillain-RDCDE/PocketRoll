# The fluid dump — riding the Pocket's savestate

*The breakthrough. [The dump saga](07-the-dump-saga.md) got photos onto SD, but every method froze the
gb and forced an exit + relaunch per batch. This chapter is how that wall finally fell — by stopping
fighting the gb and using a mechanism it already survives.*

---

## 🧱 The wall

To save the cartridge's photos we need two things, and on the Pocket they fight each other:

1. **Read the physical cart RAM** — only possible over the bus (snoop = partial, bus-master = full).
2. **Write the result to SD** — only possible with the core *quiescent* (the APF freezes it).

And the killer: **the gb survives no disruption.** We proved it four ways — gate `ce`, restore the
bank, stall via `WAIT_n`, fire `target_dataslot_write` mid-play — **all froze the gb dead.** Bus-master
*or* live SD write, the gb never came back. The relaunch-per-batch looked fundamental.

## 💡 The question that broke it

> *"But save states do it — mid-game I hit a shortcut, it writes to SD, and the game keeps going,
> smoothly. Why can't we do that?"*

Exactly right. A **savestate** pauses the gb, serialises its whole state (including cart RAM) to a
`.sta` on SD, and resumes — **fluidly, no freeze.** The gb *does* survive a pause: the savestate's,
because it's the gb's own designed mechanism (`sleep_savestate`), taken at a clean boundary. We'd been
pausing like vandals; the savestate pauses like a surgeon.

So: **let the savestate be our dump.** It already writes the cart RAM to SD, fluidly. We just had to
fix *what* cart RAM it sees.

## 🔧 Two small surgeries

A savestate serialises the gb's **internal** CRAM block RAM. In physical-cartridge mode that block RAM
is a **write-mirror** — it only holds what the gb *writes*, and the camera's photos were written long
ago by the sensor hardware, off the CPU bus. So the savestate captured an empty mirror. Two fixes:

1. **Mirror the reads** (`cart.v`): while playing a physical cart, every byte the gb *reads* from cart
   RAM is also written into the internal CRAM block RAM:
   ```verilog
   wire pr_mirror_we = cart_physical_mode & ce_cpu & cram_rd & cart_oe;
   assign cram_wr = sleep_savestate ? Savestate_CRAMRWrEn : pr_mirror_we | ...;
   wire [7:0] cram_di = sleep_savestate ? Savestate_CRAMWriteData : pr_mirror_we ? pr_phys_data : ...;
   ```
   Now as the camera reads a photo, the mirror fills with the real bytes — and the savestate sees them.

2. **Capture all of it** (`core_top`): in physical mode the ROM header isn't loaded, so `cart_ram_size`
   is mis-detected and the savestate only grabbed a slice. Force 128 KB:
   ```verilog
   wire [7:0] cart_ram_size = cart_physical_mode ? 8'd4 : cart_ram_size_raw; // 128 KB
   ```
   The `.sta` grew from 103 KB → 234 KB — the full cart RAM, in.

## ✅ Result

```
Browse a few photos → savestate (Analogue + Up) → the .sta now contains:
  cart RAM @ a findable offset, "Magic" pair 0xFE apart, directory 00 01 02
  → extract 128 KB → gbcam-sav: Active photos 3/30, Checksum OK ✅, Echo OK ✅
```

**No freeze. No relaunch.** MugDump reads the `.sta` natively (it locates the cart RAM by the GB
Camera "Magic" management pair and slices out the 128 KB). Shoot → savestate → keep shooting; pull the
PNGs at home.

## 🤖 Auto-browse — no manual scrolling

The mirror only fills with what the camera *reads*, so at first you still had to open each photo. The
fix: **let the core press the buttons.** On **L1**, an FSM injects "Right" into the gb's joypad — from
the full-screen photo view that cycles through every photo, so the camera reads them all itself, no
freeze, no hand-scrolling. Open the first photo, tap L1, watch them flip past (~8 s), take a savestate.

Two gotchas that cost a build each: **R1 is already the core's fast-forward** — triggering on R1 raced
the camera into a white-screen, so the trigger moved to **L1**; and the joypad is injected at
`joystick_0[0]` (the Right bit), synchronised across to the gb's clock. Validated: open photo 0, L1,
savestate → all three photos (incl. the two never opened by hand) come back with real pixels,
checksum OK.

So the field flow is now genuinely hands-off: **shoot → open first photo → L1 → savestate → keep
shooting.** The last piece is an in-camera **reset** to blank the roll between batches. But the dump is
*fluid and automatic* — the way it always should have been.
