# AHB Debug Unit

**Owner:** TBD
**Status:** Specification only — no RTL committed under `hw/rtl/`.
**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence, memory map, debug features | [SPI Slave Specification](SPI%20Slave%20Specification.md) — the first debug transport | [Debug Unit Verification Plan](../../verification/blocks/Debug%20Unit%20Verification%20Plan.md)

> **Not to be confused with `ahb_debug`** (`hw/rtl/interconnect/ahb_debug.sv`,
> built under `DEBUG_PERIPH`). That is a simulation-only `$fopen`/`$write`
> sink for firmware printf and instruction trace, and it does not exist in
> silicon. This block is a synthesizable bus master and CPU debug controller.
> They are unrelated; do not wire one where the other is meant.

---

## Purpose

The debug unit lets an external host reach into a running SoC: drive any
peripheral, read and write memory, and control the CPU — halt it, read back its
state, and single-step it.

It is the **bus agent**. It owns the AHB-Lite master interface, the mux that
chooses between CPU and debug access, and the CPU halt/step control. It
does *not* talk to the outside world: an external host reaches it through a
separate **debug transport** connected to the debug port defined below. The
transport is the [SPI Slave](SPI%20Slave%20Specification.md). The interface is
deliberately transport-neutral, so a different transport — JTAG or UART — could
replace the SPI slave later without touching any of the bus logic here. It is a
replacement, not an addition: there is one port and one transport
(`GRPR-DBG-003`).

Two use cases drive the design:

- **Interactive debug** — halt a running system, inspect memory and CPU state,
  single-step, resume.
- **Alternate boot path** — a host writes a firmware image directly into RAM
  and starts the CPU on it, bypassing the UART bootloader of
  [`GRPR-SOC-002`](../Grouper%20SoC%20Specification.md#boot-sequence).

Bus ownership is a **wholesale handover, not arbitration**. A lock command
swaps the owner from CPU to debug unit; a release swaps it back. There is no
arbiter, no request/grant handshake, and no interleaving.

## Protocols / Standards Conformity

| ID | Requirement |
|---|---|
| `GRPR-DBG-001` | The block shall implement an AHB-Lite manager interface and shall source read and write transfers on behalf of a connected debug transport. |
| `GRPR-DBG-002` | The block shall implement an AHB-Lite subordinate interface, so firmware can read its status and configure its consent gates. |
| `GRPR-DBG-INFO-001` | The debug port is transport-neutral by design. Nothing specific to any one transport's wire protocol belongs on it. |

## Key Functionality

### Debug Port

| ID | Requirement |
|---|---|
| `GRPR-DBG-003` | The block shall provide exactly one debug port. Exactly one debug transport shall be connected to it. |
| `GRPR-DBG-004` | The block shall implement no selection, priority, or arbitration logic between debug sources. With a single port there is nothing to select between, and adding a second source would require reopening this requirement rather than being absorbed silently. |
| `GRPR-DBG-005` | The block shall accept at most one outstanding request at a time, and shall signal acceptance and completion through the handshake of § Debug Port Interface. |

### Bus Mastering and Ownership

| ID | Requirement |
|---|---|
| `GRPR-DBG-006` | Bus ownership shall be binary and mutually exclusive: at any instant either the CPU or the debug unit sources transfers, never both. No arbitration, request/grant handshake, or interleaving of the two shall be implemented. |
| `GRPR-DBG-007` | A lock request shall be honoured only while `CTRL.LOCK_EN` is 1 and no lock is already active. Otherwise it shall be refused, bus ownership shall be undisturbed, and `STATUS.REJECTED` shall be set. |
| `GRPR-DBG-008` | The block shall contain the ownership mux for both the AHB manager path and the CPU-local RAM port, and shall force the non-owning source's `HTRANS` to IDLE and its RAM strobes inactive. |
| `GRPR-DBG-009` | Handover shall be atomic with respect to an in-flight CPU transfer. On accepting a lock the block shall assert `STATUS.LOCK_PENDING` and shall source no transfer until no CPU transfer is outstanding on either path. The in-flight transfer shall complete normally and shall never be aborted, retried, or corrupted. |
| `GRPR-DBG-010` | Debug addresses shall be 32 bits and shall be interpreted in the CPU's own memory map, such that a given address selects the same target for a debug-sourced transfer as it would for a CPU-sourced transfer under the prevailing bank-switch setting. |
| `GRPR-DBG-011` | The block shall route each request by the same address decode the CPU uses, reaching ROM, RAM, the bank-switch register, and the AHB peripheral aperture — so that any peripheral may be driven arbitrarily from a debug transport. |
| `GRPR-DBG-012` | Multi-beat transfers shall access consecutive ascending addresses. |
| `GRPR-DBG-013` | A release request shall return ownership to the CPU. Release shall not occur while a debug-sourced transfer is outstanding; the block shall complete that transfer first. A release shall be accepted from the debug transport at any time a lock is active, and shall not require any CPU or AHB access — the CPU may be halted, so a release that depended on it could never complete. |
| `GRPR-DBG-014` | A lock shall persist across transport-level events, including deassertion of a transport's chip select, until an explicit release, a watchdog expiry (`GRPR-DBG-016`), or reset (`GRPR-DBG-015`). |
| `GRPR-DBG-015` | Assertion of reset shall release any active lock, clear all debug state, and return bus ownership to the CPU. No lock state shall survive reset. |
| `GRPR-DBG-016` | The block shall implement a lockout watchdog. When `CTRL.TIMEOUT_EN` is 1, a lock that remains idle longer than the period configured by `CTRL.TIMEOUT` shall be released automatically as if by an explicit release, and shall set `STATUS.TIMEOUT`. The watchdog shall be restarted by each completed debug-sourced transfer. |
| `GRPR-DBG-017` | A debug-sourced transfer that receives an AHB error response, or that targets an address decoding to no target, shall set `STATUS.BUS_ERR`, capture the offending address and cause in `BUSADDR`/`BUSERR`, and return an error on the debug port. It shall **not** release the lock. |
| `GRPR-DBG-018` | A status read shall be answerable whether or not a lock is active, so that a host can diagnose a refused lock without CPU assistance. |

### CPU Lockout

| ID | Requirement |
|---|---|
| `GRPR-DBG-019` | The block shall support two lockout flavours, selected by `CTRL.LOCK_MODE` sampled at the instant a lock is accepted: **freeze** (`0`), in which the CPU is stalled with its program counter and architectural register state preserved; and **reset** (`1`), in which the CPU is held in reset. The sampled value shall be latched for the duration of the lock and reported in `STATUS.LOCK_MODE_ACT`. |
| `GRPR-DBG-020` | On release from a freeze-style lock the CPU shall resume execution at the instruction it was stalled on, with its program counter, general-purpose registers, and memory unchanged by the lockout itself. On release from a reset-style lock the CPU shall restart from its reset vector. |
| `GRPR-DBG-021` | A bank-switch write sourced from the debug unit during a freeze-style lock shall be refused and shall set `STATUS.BUS_ERR`. Such a write would reset the CPU out from under a state-preserving freeze and contradict `GRPR-DBG-020`. |

### CPU Debug Access

These operations require a freeze-style lock, since CPU state must survive.

| ID | Requirement |
|---|---|
| `GRPR-DBG-022` | Read, step, and resume operations shall be honoured only while `CTRL.DBG_EN` is 1 **and** `STATUS.CPU_HALTED` is 1. Issued otherwise they shall be refused and shall set `STATUS.REJECTED`. Stepping a running CPU is not meaningful and shall not be attempted. |
| `GRPR-DBG-023` | A state read shall return the CPU program counter, a selected general-purpose register, or the last retired-instruction trace record, per the selector encoding of § State Read Selectors. Values returned shall be those in effect at the instant the CPU halted, shall be stable for as long as it remains halted, and shall be unaffected by the read itself. |
| `GRPR-DBG-024` | The block shall capture the most recently retired instruction's trace record and expose it through `DBGTRACE`/`DBGTRACEH`, with a valid bit set on the first record after a step and cleared on resume. Only the most recent record shall be retained; no history buffer is required. |
| `GRPR-DBG-025` | A step shall advance the CPU by exactly the requested number of instructions (1–255; a request of 0 shall be treated as 1), return it to the halted state, and set `STATUS.STEP_DONE`. Each stepped instruction shall have the same architectural effect it would have had while running freely. |
| `GRPR-DBG-026` | The block shall provide no facility to redirect CPU execution to an arbitrary address. Execution flow is changed only by the CPU itself, or by a reset-style lock, which restarts the CPU at its reset vector. See `DBG-SPEC-002` for why an arbitrary-redirect operation was specified and then removed. |
| `GRPR-DBG-027` | A resume shall return the CPU to free-running execution from its current program counter and clear `STATUS.CPU_HALTED`. It shall leave bus ownership unchanged: resuming the CPU and releasing the bus are separate operations. |
| `GRPR-DBG-028` | Every register in § Register Map shall be readable over the AHB subordinate interface, so firmware can inspect debug and CPU state without an external host attached. |
| `GRPR-DBG-037` | The sticky `STATUS` bits (`TIMEOUT`, `REJECTED`, `BUS_ERR`, `STEP_DONE`), the `BUSADDR`/`BUSDATA`/`BUSERR` capture, and `STATUS.LOCK_MODE_ACT` shall retain their values across a lock release, and shall be cleared only by a write-1-to-clear or by reset. A debug session's outcome is therefore readable by firmware after the fact — which is the only time firmware can read it, since the CPU is halted while the session is in progress. |
| `GRPR-DBG-038` | The subordinate interface shall remain accessible to the CPU whenever the CPU is running, including while a lock is active but the CPU has not been halted. Reading these registers shall never be gated on `CTRL.DBG_EN` or `CTRL.LOCK_EN`, so a lockout can always be diagnosed from software. |
| `GRPR-DBG-029` | Reading debug state shall have no architectural side effects, and stepping shall have exactly the effect of the instructions executed and no other. |
| `GRPR-DBG-INFO-002` | The reset flavour is intended for the alternate boot path; the freeze flavour for interactive debug. `CTRL.LOCK_EN` and `CTRL.DBG_EN` are functional consent gates, **not** authentication. A host able to drive a debug transport can read all of memory and single-step the CPU. |
| `GRPR-DBG-INFO-003` | The CPU debug operations depend on CPU-side support — a register-file read port, a runtime reset vector, an instruction-retirement indication, and a program-counter output — that upstream picorv32 does not provide. See [Grouper SoC Specification § Debug/Test Features](../Grouper%20SoC%20Specification.md#debugtest-features). |

## Block Diagram

```
                    debug port(s)                  ┌──────────────┐
   transport ──────────────────────────────────▶   │              │
   (SPI S, …)   req_valid/ready, cmd, addr,        │  Debug Unit  │
                wdata, size / rsp_valid/ready,     │              │
                rdata, err                         │              │
                                                    │  ┌────────┐ │
   CPU AHB manager  ─────────────────────────────▶ │  │ owner  │ │──▶ AHB manager
   CPU RAM port     ─────────────────────────────▶ │  │  mux   │ │──▶ RAM port
                                                   │  └────────┘ │
   AHB subordinate  ◀────────────────────────────▶ │  registers  │
                                                   │             │
   CPU control  ◀──────────────────────────────────│ halt/step   │
   (freeze, reset, retire, PC, regfile)             │ step FSM    │
                                                   └──────────────┘
```

The block sits **in series** on the CPU's paths — both its AHB manager port and
its RAM port pass through the ownership mux — rather than hanging off the
fabric as a leaf peripheral. Its subordinate port is a normal fabric slot. See
`DBG-SPEC-003` for the timing consequence.

## uArch Diagram

TODO

## Debug Port Interface

The contract between a debug transport and this block. **This is the normative
definition**; other documents reference it rather than restating it.

| Signal | Direction (transport → unit) | Width | Description |
|---|---|---|---|
| `dbg_req_valid` | in | 1 | A request is presented |
| `dbg_req_ready` | out | 1 | The unit accepts the request this cycle |
| `dbg_req_cmd` | in | 4 | Operation, per § Debug Port Commands |
| `dbg_req_addr` | in | 32 | Address, or selector for a state read |
| `dbg_req_wdata` | in | 32 | Write data or step count |
| `dbg_req_size` | in | 2 | Transfer size: 0 byte, 1 halfword, 2 word |
| `dbg_rsp_valid` | out | 1 | A response is available |
| `dbg_rsp_ready` | in | 1 | The transport consumes the response this cycle |
| `dbg_rsp_rdata` | out | 32 | Read data or state readback |
| `dbg_rsp_err` | out | 1 | Bus error, unmapped address, or refused command |

A valid/ready handshake rather than a bare strobe, because the transport side
and the bus side are paced independently and a request may stall behind an
in-flight CPU transfer during handover (`GRPR-DBG-009`). Making that
backpressure explicit keeps every transport from re-inventing it.

### Debug Port Commands

| `dbg_req_cmd` | Name | Uses |
|---|---|---|
| `4'h0` | `NOP` | — |
| `4'h1` | `LOCK` | `wdata[0]` overrides `CTRL.LOCK_MODE` when `wdata[8]` is set |
| `4'h2` | `UNLOCK` | — |
| `4'h3` | `READ` | `addr`, `size` |
| `4'h4` | `WRITE` | `addr`, `wdata`, `size` |
| `4'h5` | `STATUS` | Returns `STATUS` in `rsp_rdata` |
| `4'h6` | `STATE_READ` | `addr[7:0]` = selector |
| `4'h7` | `STEP` | `wdata[7:0]` = instruction count |
| `4'h8` | `RESUME` | — |

Encodings `4'h8` and `4'hA`–`4'hF` are reserved; a request carrying one shall
be refused with `dbg_rsp_err`. `4'h8` was an arbitrary-execution-redirect
operation, removed for the reasons in `DBG-SPEC-002`; the encoding is left
vacant rather than reused, so a stale host issuing it gets a clean refusal
rather than a different operation.

### State Read Selectors

| Selector | Returns |
|---|---|
| `0x00` | CPU program counter |
| `0x01` | Last trace record, bits `[31:0]` |
| `0x02` | Trace flags in `[3:0]` (record bits `[35:32]`), record-valid in `[4]` |
| `0x10`–`0x1F` | General-purpose register `x0`–`x15` |

The GPR range covers `x0`–`x15` only: `cpu_ss` builds picorv32 as RV32E
(`ENABLE_REGS_16_31 = 0`), so `x16`–`x31` do not exist. A selector outside the
table shall be refused with `dbg_rsp_err`.

## Parameters and Configurations

| ID | Requirement |
|---|---|
| `GRPR-DBG-030` | The debug port shall not be parameterised in number. The block has one, always. |
| `GRPR-DBG-031` | `ADDR_WIDTH` and `DATA_WIDTH` shall match the SoC fabric (32 and 32). |

## IOs and External Interfaces

| Port | Direction | Width | Description |
|---|---|---|---|
| `HCLK` / `HRESETn` | in | — | System clock and reset |
| `s_H*` | — | — | AHB-Lite subordinate port (register access) |
| `m_H*` | — | — | AHB-Lite manager port (debug-sourced transfers) |
| `cpu_H*` | — | — | The CPU's AHB manager port, entering the ownership mux |
| `cpu_ram_*` | in | — | The CPU's RAM port group, entering the ownership mux |
| `ram_*` | out | — | RAM port group after the mux |
| `dbg_*` | — | — | The debug port interface above |
| `cpu_freeze` | out | 1 | Stall the CPU (freeze-style lock, and between steps) |
| `cpu_rst_req` | out | 1 | Hold the CPU in reset (reset-style lock) |
| `cpu_retire` | in | 1 | One instruction retired — drives step counting |
| `cpu_pc` | in | 32 | Current program counter |
| `cpu_reg_sel` / `cpu_reg_data` | out / in | 5 / 32 | Register-file read port |
| `cpu_trace_valid` / `cpu_trace_data` | in | 1 / 36 | picorv32 trace stream |

The `s_*`/`m_*` naming follows `hw/rtl/interconnect/ahb_conn_buff.sv`, which is
the in-repo template for an AHB manager port.

## Register Map

| Offset | Name | Access | Reset | Purpose |
|---|---|---|---|---|
| 0x00 | CTRL | R/W | 0x0000_0000 | Consent gates, lock flavour, watchdog period |
| 0x04 | STATUS | RO/W1C | 0x0000_0000 | Lock, CPU and error state |
| 0x08 | BUSADDR | RO | 0x0000_0000 | Address of the most recent debug transfer |
| 0x0C | BUSDATA | RO | 0x0000_0000 | Data of the most recent debug transfer |
| 0x10 | BUSERR | RO | 0x0000_0000 | Error capture |
| 0x14 | DBGPC | RO | 0x0000_0000 | CPU program counter |
| 0x18 | DBGTRACE | RO | 0x0000_0000 | Last trace record, low word |
| 0x1C | DBGTRACEH | RO | 0x0000_0000 | Last trace record, flags and valid |
| 0x20 | DBGREG | RO | 0x0000_0000 | Register-file read data |
| 0x24 | DBGSEL | R/W | 0x0000_0000 | Register-file read index |

Unlisted bits are reserved: read 0, write 0.

## CTRL — 0x00

| Bits | Field | Access | Description |
|---|---|---|---|
| 0 | LOCK_EN | R/W | Permit a debug transport to take the bus. The block refuses every lock while this is 0 |
| 1 | LOCK_MODE | R/W | Lock flavour for the next lock: 0 = freeze, 1 = reset |
| 2 | TIMEOUT_EN | R/W | Enable the lockout watchdog |
| 3 | DBG_EN | R/W | Permit CPU debug operations (read, step, resume) |
| 15:8 | TIMEOUT | R/W | Watchdog period, in units of 65536 `HCLK` cycles. 0 selects the maximum (256 units, ≈1.05 s at 16 MHz) |
| 31:16 | Reserved | - | Read 0, write 0 |

`LOCK_EN` and `DBG_EN` are separate so a system can permit bus access without
permitting execution control, or the reverse.

Both reset to 0 on a normally strapped chip, so it cannot be seized out of
reset; the boot ROM arms them. When the debug strap (GPIO pad 15) is sampled
high at reset they come up **set** instead, making debug reachable without any
firmware — see
[Grouper SoC Specification § Boot Flow](../Grouper%20SoC%20Specification.md#boot-flow),
`GRPR-SOC-024`, and `DBG-SPEC-001`. Firmware can clear them either way
(`GRPR-SOC-026`); the strap sets the reset value, it does not lock the gates
open.

## STATUS — 0x04

| Bits | Field | Access | Description |
|---|---|---|---|
| 0 | LOCK_ACTIVE | RO | The debug unit currently owns the bus |
| 1 | LOCK_MODE_ACT | RO | Flavour of the current or most recent lock, latched at entry |
| 2 | LOCK_PENDING | RO | A lock has been accepted; handover is waiting on an in-flight CPU transfer |
| 3 | CPU_HALTED | RO | The CPU is stopped. Distinct from `LOCK_ACTIVE`, which is about bus ownership |
| 4 | TIMEOUT | W1C | The watchdog fired and forced a release |
| 5 | REJECTED | W1C | A command was refused |
| 6 | BUS_ERR | W1C | A debug transfer took an error response or hit an unmapped address |
| 7 | STEP_DONE | W1C | A requested step count has completed |
| 31:8 | Reserved | - | Read 0 |

`CPU_HALTED` and `LOCK_ACTIVE` are deliberately independent. Bus ownership and
CPU execution state are separate concerns, and conflating them is how a lockout
becomes unreleasable.

The four W1C bits are sticky across a lock release (`GRPR-DBG-037`). That is
what makes them useful: while a debug session is in progress the CPU is
generally halted and cannot read anything, so firmware's view of what happened
is necessarily a post-mortem one, taken after the host releases. Clearing them
is firmware's job — the block never clears them on its own except at reset.

## BUSADDR — 0x08, BUSDATA — 0x0C

| Bits | Field | Access | Description |
|---|---|---|---|
| 31:0 | ADDR / DATA | RO | Address and data of the most recent debug-sourced transfer, retained after release for post-mortem inspection by firmware (`GRPR-DBG-037`) |

## BUSERR — 0x10

| Bits | Field | Access | Description |
|---|---|---|---|
| 0 | VALID | RO | An error has been captured |
| 1 | CAUSE | RO | 0 = AHB error response, 1 = unmapped address |
| 2 | WRITE | RO | 1 if the failing transfer was a write |
| 31:3 | Reserved | - | Read 0 |

The failing address is in `BUSADDR`.

## DBGPC — 0x14, DBGTRACE — 0x18, DBGTRACEH — 0x1C

| Register | Bits | Field | Access | Description |
|---|---|---|---|---|
| DBGPC | 31:0 | PC | RO | CPU program counter. Valid while `STATUS.CPU_HALTED` is 1 |
| DBGTRACE | 31:0 | RECORD | RO | Last trace record, bits `[31:0]` — the branch target on a branch record, otherwise the write-back value |
| DBGTRACEH | 3:0 | FLAGS | RO | Trace record bits `[35:32]`: bit 0 `BRANCH`, bit 1 `ADDR`, bit 3 `IRQ` |
| DBGTRACEH | 4 | VALID | RO | A record has been captured since the last resume |
| DBGTRACEH | 31:5 | Reserved | - | Read 0 |

Flag encodings follow picorv32's `TRACE_BRANCH`/`TRACE_ADDR`/`TRACE_IRQ`.

## DBGREG — 0x20, DBGSEL — 0x24

| Register | Bits | Field | Access | Description |
|---|---|---|---|---|
| DBGREG | 31:0 | DATA | RO | Contents of the register selected by `DBGSEL` |
| DBGSEL | 4:0 | SEL | R/W | Register index. Only `0`–`15` exist on this RV32E core; `16`–`31` read 0 |
| DBGSEL | 31:5 | Reserved | - | Read 0, write 0 |

`DBGSEL` is the only writable debug register: firmware may want to inspect its
own register file at a breakpoint with no external host attached.

**When firmware can use these.** `DBGPC`, `DBGREG` and the trace registers
report CPU state captured while the CPU was halted, so their contents are
meaningful to a *running* CPU only after a debug session has ended. Two cases
are useful. After a host releases a lock, firmware can read back what the
session saw. And firmware can read `DBGREG` against its own live register file
at a breakpoint of its own making — the read port is not gated on a lock being
active — which is what makes a firmware-only breakpoint handler possible with
no external host at all.

There is deliberately **no CPU-writable bus-command register**. The CPU already
has the bus, so a second control surface would add verification burden and no
capability. Do not add write paths to `BUSADDR`/`BUSDATA`/`BUSERR`.

## Clocking Strategy

| ID | Requirement |
|---|---|
| `GRPR-DBG-032` | The block shall be fully synchronous to `HCLK`, in a single clock domain. Any clock-domain crossing to a transport's own clock is the transport's responsibility, not this block's. |

## Reset Strategy

| ID | Requirement |
|---|---|
| `GRPR-DBG-033` | The block shall have an active-low reset, asynchronously asserted and synchronously de-asserted, consistent with the rest of the SoC. |

Reset releases any lock and returns bus ownership to the CPU (`GRPR-DBG-015`).
Because the block gates the CPU's reset and stall inputs, its own reset must
leave those deasserted, so that a reset never leaves the CPU stranded.

## CDC Strategy

Single clock domain; no crossing inside this block. The debug port is
synchronous to `HCLK`, so a transport in another domain must synchronise on its
side before presenting a request.

## Performance Targets

| ID | Requirement |
|---|---|
| `GRPR-DBG-034` | A debug-sourced word transfer to the AHB aperture shall complete in no more than 4 `HCLK` cycles plus whatever wait states the target subordinate inserts. |
| `GRPR-DBG-035` | A debug-sourced word transfer to RAM shall complete in no more than 3 `HCLK` cycles, RAM being a fixed single-cycle target. |
| `GRPR-DBG-036` | Handover latency, from an accepted lock to `STATUS.LOCK_ACTIVE`, shall be bounded by the longest CPU transfer the fabric permits. |

## Size Estimate

TBD — not yet confirmed by synthesis. This block adds a register file, an AHB
manager FSM, two ownership muxes, and a step counter. For scale, the
`ahb_stub_slave` placeholders currently budget 1706 GE for the SPI Master slot
and 635 GE for the SPI Slave (`hw/rtl/periph_ss.sv`). An early `make measure-ge`
run is warranted before this specification is frozen — see `DBG-SPEC-004`.

## Open Items

- `DBG-SPEC-001` — **Resolved by the debug strap.** `CTRL.LOCK_EN` still resets
  to 0 in the normal case, so a chip is not seizable by default. Holding GPIO
  pad 15 high at reset instead brings the consent gates up set and gives pads
  0–3 their SPI-slave function in hardware
  ([`GRPR-SOC-024`](../Grouper%20SoC%20Specification.md#gpio-multiplexing-scheme)),
  making debug reachable with no firmware involvement — including on a chip
  whose boot ROM does not run. What remains open is board-level: a floating pad
  15 would arm debug by accident, so that pad needs a reset-default pull-down
  or a stated board requirement. Tracked in the SoC spec's open items.
- `DBG-SPEC-002` — **Resolved: arbitrary execution redirect is out of scope.**
  An earlier draft specified a jump operation. picorv32 has no architectural
  path to write `reg_pc` from outside, so the only available lever was the
  reset vector — and reset also clears `cpuregs`. A "jump" that destroys the
  register file is not useful for debug, since the state a debugger wants to
  inspect and continue from is exactly what it would discard, and a reset-style
  lock already provides restart-from-reset-vector behaviour for the boot path.
  The operation was therefore removed rather than shipped with a misleading
  name. Should a genuine non-destructive redirect be wanted later it needs a
  PC-write port on the CPU fork, which is a larger change than it appears:
  writing `reg_pc` mid-flight has to be sequenced against picorv32's own
  control FSM.
- `DBG-SPEC-003` — **In-series topology is a timing risk.** Both CPU paths pass
  through this block's ownership mux, and the RAM path is already the long
  combinational path in the design
  ([`GRPR-SOC-008`](../Grouper%20SoC%20Specification.md#interconnect-architecture)).
  The mux should be combinational and thin. A registered mux would break
  `cpu_ss`'s single-cycle RAM assumption and require that logic reworked.
- `DBG-SPEC-004` — Size estimate not yet available; see § Size Estimate.
- `DBG-SPEC-005` — **Freeze has observable side effects outside the CPU.** A
  frozen CPU services no interrupts, so a long freeze can overrun the UART RX
  FIFO or lose peripheral events. `GRPR-DBG-020` is scoped to CPU architectural
  state for that reason. A stated data-loss expectation for long freezes is
  still needed.
- `DBG-SPEC-006` — Whether the step-retirement indication should be picorv32's
  `trace_valid` or a dedicated output. `trace_valid` exists only when the core
  is built with `ENABLE_TRACE`, which is currently off in silicon, so dropping
  trace for area would also remove the step mechanism. The two are coupled and
  must be decided together.
- `DBG-SPEC-007` — **Resolved: one debug port, no arbitration.** An earlier
  draft parameterised the port count and specified a fixed-priority selection
  between transports. That has been removed: the block has exactly one port
  (`GRPR-DBG-003`) and no selection logic (`GRPR-DBG-004`). Supporting a second
  concurrent transport would need this requirement reopened deliberately, which
  is the intent — it is a decision, not an omission.

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-DBG-001` | `V-DBG-STM-001`, `V-DBG-CHK-001` |
| `GRPR-DBG-002` | `V-DBG-STM-002`, `V-DBG-CHK-002`, `V-DBG-DIR-001`…`-005` |
| `GRPR-DBG-003` | `V-DBG-CHK-003` (exactly one port present) |
| `GRPR-DBG-004` | `V-DBG-CHK-029` (negative check: no selection or priority logic exists) |
| `GRPR-DBG-005` | `V-DBG-CHK-004` |
| `GRPR-DBG-006` | `V-DBG-CHK-005` (assertion: never two non-IDLE sources), `V-DBG-DIR-011` |
| `GRPR-DBG-007` | `V-DBG-STM-004`, `V-DBG-CHK-006`, `V-DBG-DIR-009` |
| `GRPR-DBG-008` | `V-DBG-CHK-007`, `V-DBG-DIR-011` |
| `GRPR-DBG-009` | `V-DBG-STM-005`, `V-DBG-CHK-008`, `V-DBG-DIR-010` |
| `GRPR-DBG-010` | `V-DBG-STM-006`, `V-DBG-CHK-009`, `V-DBG-DIR-014` |
| `GRPR-DBG-011` | `V-DBG-STM-007`, `V-DBG-COV-001`, `V-DBG-DIR-015` |
| `GRPR-DBG-012` | `V-DBG-STM-008`, `V-DBG-DIR-016` |
| `GRPR-DBG-013` | `V-DBG-CHK-010`, `V-DBG-DIR-008`, `-012`, `-013` |
| `GRPR-DBG-014` | `V-DBG-STM-009`, `V-DBG-DIR-018` |
| `GRPR-DBG-015` | `V-DBG-STM-010`, `V-DBG-CHK-011`, `V-DBG-DIR-019` |
| `GRPR-DBG-016` | `V-DBG-STM-011`, `V-DBG-CHK-012`, `V-DBG-DIR-020`, `-021` |
| `GRPR-DBG-017` | `V-DBG-STM-012`, `V-DBG-CHK-013`, `V-DBG-DIR-017` |
| `GRPR-DBG-018` | `V-DBG-CHK-014` |
| `GRPR-DBG-019` | `V-DBG-STM-013`, `V-DBG-COV-002`, `V-DBG-DIR-022`…`-024` |
| `GRPR-DBG-020` | `V-DBG-CHK-015`, `V-DBG-DIR-022`, `-023` |
| `GRPR-DBG-021` | `V-DBG-STM-014`, `V-DBG-CHK-016`, `V-DBG-DIR-025` |
| `GRPR-DBG-022` | `V-DBG-STM-015`, `V-DBG-CHK-017`, `V-DBG-DIR-026` |
| `GRPR-DBG-023` | `V-DBG-STM-016`, `V-DBG-CHK-018`, `V-DBG-DIR-027`, `-028` |
| `GRPR-DBG-024` | `V-DBG-CHK-019`, `V-DBG-DIR-029` |
| `GRPR-DBG-025` | `V-DBG-STM-017`, `V-DBG-CHK-020`, `V-DBG-DIR-030` |
| `GRPR-DBG-026` | `V-DBG-CHK-021` (negative check: no redirect operation is accepted), `V-DBG-DIR-031` |
| `GRPR-DBG-027` | `V-DBG-CHK-022`, `V-DBG-DIR-032` |
| `GRPR-DBG-028` | `V-DBG-STM-019`, `V-DBG-DIR-001`, `-006` |
| `GRPR-DBG-037` | `V-DBG-STM-021`, `V-DBG-CHK-030`, `V-DBG-DIR-004`, `-006` |
| `GRPR-DBG-038` | `V-DBG-CHK-031`, `V-DBG-DIR-007` |
| `GRPR-DBG-029` | `V-DBG-CHK-023`, `V-DBG-DIR-027` |
| `GRPR-DBG-030` | `V-DBG-CHK-024` (no port-count parameter exists) |
| `GRPR-DBG-031` | *(parameter range — elaboration-checked)* |
| `GRPR-DBG-032` | `V-DBG-CHK-025` |
| `GRPR-DBG-033` | `V-DBG-STM-010`, `V-DBG-CHK-011`, `V-DBG-DIR-019` |
| `GRPR-DBG-034` | `V-DBG-CHK-026` |
| `GRPR-DBG-035` | `V-DBG-CHK-027` |
| `GRPR-DBG-036` | `V-DBG-CHK-028` |

See [Debug Unit Verification Plan](../../verification/blocks/Debug%20Unit%20Verification%20Plan.md)
for the full item definitions and test list.
