# Dump via bus-master read — design blueprint

Goal: on a trigger, the core reads the **physical cartridge's 128 KB SRAM itself** (the source of
truth — valid `"Magic"`, directory, photos) into a clean buffer, then writes that buffer to SD with
`target_dataslot_write`. This replaces the failed write-mirror + `save_handler` approach
(see [docs/07](../docs/07-the-dump-saga.md)).

## Why bus-master (recap)

The camera stays 100% on its real cartridge (passthrough — works perfectly, live sensor included). The
only thing we add for the dump is: **briefly take over the cartridge bus and read all of SRAM.** No
mirror, no banking shadow, no `save_handler` quirks.

## What the trace found (core_top.sv)

- The `gb` module (L1008) **drives** the cartridge bus signals (its outputs):
  `cart_addr[14:0], cart_a15, cart_rd, cart_wr, cart_di[7:0], nCS` (L1025-1034), declared as `logic`
  at L715-718.
- Those signals feed **both** `cart_top` (backend) **and** the physical pins:
  `cart_tran_bank2 = {cart_a15, cart_addr[14:8]}`, `cart_tran_bank3 = cart_addr[7:0]`,
  `cart_tran_bank1 = cart_write_access ? cart_di : 8'hzz` (read → tristate → cart drives it),
  control on `cart_tran_bank0` (RD/WR/CS), all gated by `cart_access = cart_physical_mode & (rd|wr)`.
- Read data comes back on **`cart_tran_bank1`** (the same pins, when not writing).
- Cartridge bus timing = **`cart_phi`** counter (`cart_phi_period_m1` = 31 @ normal speed; `cart_phi_rise`
  fires once per cart cycle). The `gb` core paces its own `cart_rd`/`cart_wr` to this.
- The `gb` core has a **`sleep_savestate`** input (L1073) that pauses it; `ce_cpu` (L1013) is its clock
  enable.

## The plan

**1. Mux the bus between the CPU and a dump FSM.** Rename the `gb` outputs to `gb_cart_*` and select:

```verilog
wire pr_busmaster;                       // high while dumping
assign cart_addr = pr_busmaster ? pr_addr : gb_cart_addr;
assign cart_a15  = pr_busmaster ? pr_a15  : gb_cart_a15;
assign cart_rd   = pr_busmaster ? pr_rd   : gb_cart_rd;
assign cart_wr   = pr_busmaster ? pr_wr   : gb_cart_wr;
assign cart_di   = pr_busmaster ? pr_di   : gb_cart_di;
assign nCS       = pr_busmaster ? pr_ncs  : gb_cart_ncs;
```

The existing `cart_tran_*` logic then puts *our* address/control on the pins and tristates for reads —
**we reuse the whole physical bus interface**, we only supply the address.

**2. Pause the CPU** while `pr_busmaster` (gate `ce_cpu`, or assert `sleep_savestate`) so the GB core
doesn't fight for the bus. The camera freezes for the dump (~1 s for 128 KB) then resumes — fine for a
once-per-30-photos operation.

**3. The read FSM** (clk_sys / ce_cpu domain, paced by `cart_phi_rise`). The Camera RAM is a 8 KB window
`0xA000-0xBFFF` banked by a register write to `0x4000-0x5FFF` (bit 4 = 0 → RAM, low nibble = bank).
16 banks × 8 KB = 128 KB. So:

```
for bank in 0..15:
    bus-write 0x4000 = {0,bank}        // select RAM bank, cam_en=0 (NOT sensor)
    for off in 0x0000..0x1FFF:
        bus-read 0xA000+off            // drive addr+RD, wait cart_phi_rise, sample cart_tran_bank1
        dump_buf[bank*0x2000 + off] <= data
```

Each bus cycle = drive `pr_addr`/`pr_rd`(or `pr_wr`+`pr_di`)/`pr_ncs`, wait one `cart_phi` period for the
cartridge to drive the pins, latch `cart_tran_bank1`. `nCS` low for the `0xA000-0xBFFF` window, `cart_a15`
per address.

**4. Buffer.** `dump_buf` = a 128 KB block RAM (e.g. 64 K × 16, or 128 K × 8). Written by the FSM, read by
the bridge.

**5. Expose `dump_buf` to the bridge** at a **clean dedicated address** (e.g. `0x30000000`), where
`bridge_addr[16:0]` indexes the buffer directly (combinational/registered read into `bridge_rd_data`).
Unlike `save_handler`'s region, this is a plain RAM window — safe to read arbitrarily.

**6. Then fire the SD write** we already have working: `target_dataslot_write` with
`bridgeaddr = 0x30000000`, `length = 0x20000`, to the `pocketroll.sav` slot. (Slot still needs a
non-zero size → keep pre-creating / set it in the datatable.)

## Sequencing (one trigger → one file)

`idle → (trigger) → pause CPU + pr_busmaster → bank/offset read loop → fill dump_buf → release bus/CPU →
target_dataslot_write from 0x30000000 → wait done → idle`.

## Risks to watch (before burning a 1 h compile)

- **Bus timing**: match the cartridge read setup — drive address/`nCS`/RD, wait a full `cart_phi` period
  before latching `cart_tran_bank1`. Too fast = garbage. (Mirror the timing the `gb` core already uses.)
- **cam_en**: the bank-select writes must keep bit 4 = 0 so `0xA000-0xBFFF` is **RAM, not the sensor**.
- **Tristate/direction**: for reads, `cart_tran_bank1_dir` must be input (the existing logic does this
  when `~cart_write_access`; ensure our `pr_rd`/`pr_wr` drive `cart_access` correctly).
- **Pause cleanliness**: resuming the CPU after the dump must not corrupt camera state (gating `ce_cpu`
  holds it; verify it picks up cleanly).
- **CDC**: FSM in clk_sys, `target_dataslot_*` in clk_74a — cross with a simple handshake/flag.

## What this proves

One trigger → `pocketroll.sav` on SD that is **byte-identical to the cartridge SRAM** → MugDump reads the
photos. Then the same bus-master write path frees the film (the **reset**), and we automate "every 30".
