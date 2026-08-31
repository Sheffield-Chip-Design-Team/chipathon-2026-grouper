# Debug response timing: what was wrong, and what was not

Working notes from an investigation into `BUS_STATUS` returning `0x00000004`
where the Debug Unit held `0x00000009`, at the SoC level
(`sharc:soc_ip:grouper_soc_directed --target=debug_unit`,
`hw/tb/top/test_debug.py`).

Short version: **the SPI Slave RTL was correct throughout.** Every RTL change
attempted during this investigation was reverted. The fault was in the
testbench SPI master models, and specifically in how they relate SCK to the
core clock.

## The RTL is correct

Traced against `spi_s_tx`'s own `bit_count` and `shift`, the final byte of a
`BUS_STATUS` response puts this on MISO across its eight SCK-high phases:

| `shift` | `0x09` | `0x12` | `0x24` | `0x48` | `0x90` | `0x20` | `0x40` | `0x80` |
|---|---|---|---|---|---|---|---|---|
| `miso` | 0 | 0 | 0 | 0 | **1** | 0 | 0 | **1** |

`0b00001001` = `0x09`. The slave transmits STATUS correctly, byte-aligned,
with all four bytes in order (`0x00, 0x00, 0x00, 0x09`) and the last bit
launched before the frame ends.

## The wire timing rule

The slave launches a new MISO bit on the **falling** edge (`launch_edge` in
`spi_s_core.sv`, mode 0). So the bit belonging to a period is already on the
wire when that period *starts*:

```
SCK   ‾‾\_________/‾‾‾‾‾‾‾‾‾\_________/‾‾‾
        ^                    ^
        |                    +-- launches bit n+1
        +----------------------- launches bit n
      ^                        ^
      |                        +-- sample bit n+1 here
      +--------------------------- sample bit n here (top of its period)
```

A master must sample at the **top of each bit period**, before driving that
period's own SCK pulse. Sampling after the pulse reads the bit the *next*
falling edge produces, shifting the whole response left one position:
`0x09` decodes as `0x12`.

This was pinned down in `hw/tb/debug/test_spi_dbg.py` (below), not at the SoC
level.

## The pad model is a simulation artefact

`PadModel` (`hw/tb/top/test_soc.py`) drives `gpio_in` from Python without
racing the DUT's own continuous driver: `set_pads()` sets a variable and
`_run()` applies it on the following `RisingEdge`. That one-clock delay does
not exist in silicon. `io_ss.sv` has no such register; a real pad drives its
input buffer combinationally, and the only sequential element in that path is
the 2-FF synchroniser in `grouper_soc_top`, which is already in the RTL and
already in simulation.

`spi_pad_master.py` originally ran SCK at **3 core clocks per bit**. At that
rate the pad model's one clock is a third of a bit period, so the capture
landed on the wrong bit entirely and STATUS read back as `0x04`. Widening the
period to 8 core clocks per bit (`sck_half=4`) restores the margin and the
artefact disappears -- the residual error then became the plain `0x12`
signature above, i.e. the same wire-timing rule, no longer masked.

Real hardware has no equivalent hazard: a host clocks SCK far slower than the
core clock, giving this relationship tens of clocks of margin.

**Lesson for future SPI benches:** drive SCK slowly enough that the sample
point is nowhere near a transition, rather than compensating for
testbench-side delays by counting core clocks.

## Two real RTL fixes, from earlier in the same work

These are genuine silicon bugs and are **not** part of the revert above.

1. **`spi_s_tx.sv` -- `reload`.** A byte boundary took two steps (launch edge
   clears `busy`, next clock loads) where a mid-byte bit takes one, so every
   byte after the first launched its MSB a clock late -- level with the
   host's sample edge instead of ahead of it. `0xAD` read back as `0x2D`.
   Broken at any SCK rate. `test_debug_write_reaches_ram` now uses
   `0xDEADBEEF` rather than `0x12345678`, which has bit 7 clear in every byte
   and could never detect this.

2. **`cpu_ss.sv` -- `dbg_ram_read_pending`.** `ram_ss`'s read port is
   registered but `mem_ready` was hardwired `1'b1`, so the debug port sampled
   stale `ram_rdata`. Verified load-bearing: disabling it makes a read of
   `0x12345678` return `0x90, 0x06, 0x23, 0x04`.

## Theories that the traces killed

Recorded so they are not re-proposed:

- **`PUSH_WAIT` hangs across frames.** No: `fixed_len_push_state` is reset by
  `flush || spi_ss`, a *level*, and SS is high for the whole inter-frame gap.
  Traced cleanly cycling `PUSH_IDLE -> PUSH_BYTE -> PUSH_WAIT -> PUSH_IDLE`
  every frame.
- **Stale STATUS captured during the `LOCK_PENDING` cycle.** No: traced
  `lock_active=1, lock_pending=0, status_word=0x09` at every capture, on all
  four polls.
- **A phantom `0x00` prepended because `load` fires against a stale
  `hold_valid`.** No: gating `send_en` on the response having reached the
  holding register (`fixed_len_tx_armed`) arms at 101900ns, long before
  `FSM_READ_DATA` at 103600ns, so it never fires and changes nothing.
- **The last bit is never launched because `FSM_READ_DATA` exits on the
  sample edge.** Partially real but not the cause -- extending `send_en` with
  `tx_busy` did make the last launch happen, but the byte was already correct
  on the wire before it. Reverted.

## The bench that made this tractable

`sharc:soc_ip:spi_dbg_directed` (`hw/tb/debug/`) wires `ahb_spi_s` straight to
`dbg_ctrl` with only the CPU side stubbed (the existing `CpuStub`):

| file | role |
|---|---|
| `spi_dbg_top.sv` | the two real blocks, no CPU/RAM/pad mux |
| `spi_dbg_directed.core` | `fusesoc run --no-export sharc:soc_ip:spi_dbg_directed` |
| `spi_wire_master.py` | SPI master on pins, parameterised `sck_half` |
| `test_spi_dbg.py` | 7 tests: STATUS, repeated STATUS, pre-lock STATUS, write/read, stub-memory read, RESUME, UNLOCK |

It reproduces the same wire behaviour in **~0.4 s** against a ~90 us firmware
boot at the SoC level, and it is where the timing rule above was derived.
7/7 pass against pristine RTL.

Neither block-level suite covers this seam:
`sharc:comms_ip:ahb_spi_s_directed --target=debug_port` drives `ahb_spi_s`
against a Python `DebugStub`; `sharc:soc_ip:ahb_debug_unit_directed` drives
`dbg_ctrl` against a Python `CpuStub`. Each stubs out the other side, so a
response-phase timing bug between them only ever appeared at the full SoC
level.

## A third real RTL fix: bus ownership vs CPU execution

Found once the SPI timing above stopped masking it, and fixed in
`hw/rtl/cpu_ss.sv`.

`dbg_own` is `LOCK_ACTIVE` for the **whole lock** (`dbg_ctrl.sv`), but a lock
and a debug *transfer* are not the same window. STEP and DBG_RESUME both clear
`cpu_freeze` while the lock is still held (GRPR-DBG-025/-027), so the CPU is
meant to execute during part of a lock. The ownership mux and the CPU's
completion signal disagreed about that:

- the mux keyed on `dbg_own`, so `mem_la_*` pointed at the debug port even
  when it was not asking for anything, and the CPU's own fetches and stores
  never reached memory;
- `cpu_mem_ready = mem_ready && !cpu_freeze` told the CPU those transfers had
  nonetheless completed, handing it `mem_rdata` from the debug port.

picorv32 retired whatever that happened to hold. Observed as the PC collapsing
from the heartbeat loop to ~0 within 2.6 us of a DBG_RESUME issued before
BUS_UNLOCK, after which the counter never advanced again:

```
112300ns  freeze=1 own=1 halted=1 lock=1  pc~=0x100
349400ns  freeze=0 own=1 halted=0 lock=1  pc~=0x100   <- DBG_RESUME
352000ns  freeze=0 own=1 halted=0 lock=1  pc~=0x000   <- program lost
396600ns  freeze=0 own=0 halted=0 lock=0  pc~=0x000   <- unlock, too late
```

The fix keys both on the debug unit's actual transfer:

```systemverilog
logic dbg_bus_active;
assign dbg_bus_active = dbg_own && dbg_req;
// ... mux on dbg_bus_active, not dbg_own
assign cpu_mem_ready = mem_ready && !cpu_freeze && !dbg_bus_active;
```

Exclusivity is preserved -- the debug unit wins every cycle it actually wants
the bus, and the CPU stalls mid-transfer with its architectural state intact,
exactly as under a freeze. Gating on `dbg_own` instead would stall the CPU for
the entire lock and a STEP could never retire anything, which is precisely the
independence GRPR-DBG-025 requires.

## Status

All green:

| suite | result |
|---|---|
| `sharc:soc_ip:spi_dbg_directed` | 7/7 |
| `sharc:soc_ip:grouper_soc_directed --target=debug_unit` | 3/3 |
| `sharc:soc_ip:ahb_debug_unit_directed` (incl. STEP) | 24/24 |
| `sharc:comms_ip:ahb_spi_s_directed --target=debug_port` | 19/19 |
| `sharc:soc_ip:grouper_soc_directed` (default) | 1 pass, 0 fail, 6 skip |

`--target=tb_top` on `grouper_soc_tb` still fails, but at the *link* step
(`region 'ROM' overflowed by 1436 bytes` building `sw/src/main.c`) before any
RTL runs. Pre-existing and unrelated.

The pad master (`hw/tb/debug/spi_pad_master.py`) now runs SCK at 8 core clocks
per bit (`sck_half=4`) and samples at the midpoint of the SCK-low phase, where
the slave's falling-edge launch has settled onto the pad.
