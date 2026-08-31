# AHB Debug Unit

**Owner:** TBD
**Status:** Specification. Skeleton RTL under `hw/rtl/debug/` (`dbg_ctrl.sv`,
`dbg_regs.sv`) — port lists only, no logic.
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

It is the **bus agent**, and it sits **inside `cpu_ss`**. It does not own any of
the subsystem's outgoing ports. It sources a native-memory-interface request —
address, write data, byte strobes — alongside an ownership signal, and `cpu_ss`
muxes that against the CPU's own request. When it has ownership, its request is
what drives the ROM, RAM and AHB manager ports; when it does not, it drives
nothing and `cpu_ss` is a wire. It also owns the CPU halt/step control. It
does *not* talk to the outside world: an external host reaches it through a
separate **debug transport** connected to the debug port defined below. The
transport is the [SPI Slave](SPI%20Slave%20Specification.md). The interface is
deliberately transport-neutral, so a different transport — JTAG or UART — could
replace the SPI slave later without touching any of the bus logic here. It is a
replacement, not an addition: there is one port and one transport
(`GRPR-DBG-003`).

**A transport need not expose every command.** The port defines the full
command set; how much of it a given transport can frame is that transport's
concern. The SPI Slave reaches it through a **dedicated debug opcode set**,
distinct from its data commands: `BUS_LOCK`/`BUS_UNLOCK`/`BUS_STATUS`/
`DBG_READ`/`DBG_STEP`/`DBG_RESUME`/`DBG_ENABLE`, plus a 32-bit-addressed
`BUS_READ`/`BUS_WRITE` pair that reaches the whole memory map, peripherals
included — see
[SPI Slave § Debug Command Encoding](SPI%20Slave%20Specification.md#debug-command-encoding).

That transport's **legacy APS6404L data commands** (`SPI_READ`, `SPI_WRITE`,
`FAST_READ`, `FAST_WRITE`) are *not* part of this path. They never reach the
debug port under any register or parameter setting: they always run through
the SPI Slave's own RX/TX FIFOs, with their 24-bit APS6404L addressing
intact. An earlier revision retargeted them at the debug port under a
`CTRL.DEBUG_PORT_EN` register bit; that mechanism, the register bit, and the
reach limit that went with it are all withdrawn
([`GRPR-SPIS-030`](SPI%20Slave%20Specification.md), `-031`, `-016`), which is
why there are no longer "two tiers" of debug-capable wire opcode — there is
one.

Register access (`REG_READ`/`REG_WRITE`) stays reachable only through the
transport's AHB register window
([`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)),
by design, not because the wire side lacks room for it. Nothing in this block
is conditioned on which transport is attached.

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
| `GRPR-DBG-001` | The block shall sit inside `cpu_ss`, alongside the CPU rather than in series with it, and shall present **no** port at the CPU-subsystem boundary. It shall source a single native-memory-interface request — `dbg_own`, `dbg_req`, `dbg_write`, `dbg_addr`, `dbg_wdata`, `dbg_wstrb` — into the ownership mux of `GRPR-DBG-008`, which is `cpu_ss` logic and not part of this block. The subsystem's ROM, RAM and AHB manager ports are unchanged in number and in meaning, and downstream logic shall not know which owner drove a given transfer. |
| `GRPR-DBG-002` | The block shall implement **neither** an AHB-Lite manager nor an AHB-Lite subordinate interface. It reaches the bus only through the mux of `GRPR-DBG-008` and `cpu_ss`'s existing native-to-AHB conversion, so no AHB protocol logic belongs here. It occupies no fabric slot and no address of its own — it is not a leaf peripheral, and it has no path by which a bus transfer can reach its own registers. Those are reached over the debug port (`GRPR-DBG-039`). The CPU reaches them **indirectly**, through a window in the transport's aperture ([`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)) which turns an AHB access into a `REG_READ`/`REG_WRITE`. |
| `GRPR-DBG-042` | The debug port (`dbg_req_*` in, `dbg_rsp_*` out) shall be brought out to the `cpu_ss` boundary unchanged, so that the transport connects to `cpu_ss` and this block is not visible outside it. |
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
| `GRPR-DBG-008` | The ownership mux shall be `cpu_ss` logic, placed on the CPU's **native look-ahead interface** (`mem_la_*`) upstream of the ROM/RAM/bank-switch/AHB address decode. It is a single mux, not one per outgoing port group: because it sits before the decode, all three port groups follow from it, and no port-group-specific muxing exists. When `dbg_own` is 0 the mux shall select the CPU unconditionally and this block's request signals shall have no effect. When `dbg_own` is 1 it shall select this block, and the CPU's read and write strobes into the decode shall be inactive, which holds `HTRANS` at IDLE and the ROM and RAM strobes deasserted for the non-owner without any separate forcing logic. |
| `GRPR-DBG-043` | Ownership shall also gate transfer completion back to the CPU: while `dbg_own` is 1, `cpu_ss` shall hold picorv32's `mem_ready` low, and shall return the mux'd completion to this block as `dbg_ready`/`dbg_rdata` instead. Holding `mem_ready` low is what stalls the CPU mid-transfer, and is the mechanism by which a freeze-style lock (`GRPR-DBG-019`) preserves architectural state. |
| `GRPR-DBG-044` | On accepting a lock, the block shall assert a dedicated 1-bit output, `dbg_lock_active`, tracking `STATUS.LOCK_ACTIVE`. This shall be brought out to the `cpu_ss` boundary alongside the debug port (`GRPR-DBG-042`) rather than kept internal, so that logic outside `cpu_ss` — specifically the pad output-enable gate of [GPIO Mux `GRPR-GPIO-016`](GPIO%20Mux%20Specification.md) — can act on it directly. This is a hardware signal, not a register a host reads: it shall take effect the same cycle `STATUS.LOCK_ACTIVE` does, with no dependency on any bus access being available, for the same reason `GRPR-DBG-013` does not depend on one — the CPU may be halted or the bus otherwise unavailable at the moment ownership changes. |
| `GRPR-DBG-009` | Handover shall be atomic with respect to an in-flight CPU transfer. On accepting a lock the block shall assert `STATUS.LOCK_PENDING` and shall source no transfer until no CPU transfer is outstanding on either path. The in-flight transfer shall complete normally and shall never be aborted, retried, or corrupted. |
| `GRPR-DBG-010` | Debug addresses shall be 32 bits and shall be interpreted in the CPU's own memory map, such that a given address selects the same target for a debug-sourced transfer as it would for a CPU-sourced transfer under the prevailing bank-switch setting. |
| `GRPR-DBG-011` | Each request shall be routed by the **same** address decode the CPU uses, reaching ROM, RAM, the bank-switch register, and the AHB peripheral aperture — so that any peripheral may be driven arbitrarily from a debug transport. This follows from the mux placement of `GRPR-DBG-008` rather than from decode logic here: the block presents an address and the existing `cpu_ss` decode acts on it. No second decode shall be implemented. |
| `GRPR-DBG-012` | Multi-beat transfers shall access consecutive ascending addresses. |
| `GRPR-DBG-013` | A release request shall return ownership to the CPU. Release shall not occur while a debug-sourced transfer is outstanding; the block shall complete that transfer first. A release shall be accepted from the debug transport at any time a lock is active, and shall not require any CPU or AHB access — the CPU may be halted, so a release that depended on it could never complete. |
| `GRPR-DBG-014` | A lock shall persist across transport-level events, including deassertion of a transport's chip select, until an explicit release (`GRPR-DBG-013`) or reset (`GRPR-DBG-015`). |
| `GRPR-DBG-015` | Assertion of reset shall release any active lock, clear all debug state, and return bus ownership to the CPU. No lock state shall survive reset. |
| `GRPR-DBG-016` | *(Withdrawn.* The lockout watchdog and its `CTRL.TIMEOUT`/`CTRL.TIMEOUT_EN` configuration are removed. A lock ends only by an explicit release (`GRPR-DBG-013`) or by reset (`GRPR-DBG-015`). See `DBG-SPEC-010` for what this costs.)* |
| `GRPR-DBG-017` | A debug-sourced transfer that receives an AHB error response, or that targets an address decoding to no target, shall set `STATUS.BUS_ERR`, capture the offending address and cause in `BUSADDR`/`BUSERR`, and return an error on the debug port. It shall **not** release the lock. The error indication is `cpu_ss`'s existing `bus_error`, qualified by `dbg_own`; the same signal drives the CPU's IRQ 2 when the CPU owns the bus. A debug-sourced error shall **not** raise that interrupt. |
| `GRPR-DBG-018` | A `STATUS` command shall be answerable whether or not a lock is active, so that a host can diagnose a refused lock without CPU assistance. It travels the debug port, which is the host's only interface to this block. |

### CPU Lockout

| ID | Requirement |
|---|---|
| `GRPR-DBG-019` | The block shall support two lockout flavours, selected by `CTRL.LOCK_MODE` sampled at the instant a lock is accepted: **freeze** (`0`), in which the CPU is stalled with its program counter and architectural register state preserved; and **reset** (`1`), in which the CPU is held in reset. The sampled value shall be latched for the duration of the lock and reported in `STATUS.LOCK_MODE_ACT`. |
| `GRPR-DBG-020` | On release from a freeze-style lock the CPU shall resume execution at the instruction it was stalled on, with its program counter, general-purpose registers, and memory unchanged by the lockout itself. On release from a reset-style lock the CPU shall restart from its reset vector. |
| `GRPR-DBG-021` | A bank-switch write sourced from the debug unit during a freeze-style lock shall be refused and shall set `STATUS.BUS_ERR`. Such a write would reset the CPU out from under a state-preserving freeze and contradict `GRPR-DBG-020`. The refusal shall be made **here**, by not issuing the request into the mux: `cpu_ss`'s bank-switch logic already accepts a debug-sourced write (it selects `dbg_addr_r`/`dbg_wdata_r` when `dbg_own` is set) and asserts `cpu_rst_n` low on it, so a request that reaches the mux is unconditionally honoured and cannot be refused downstream. |

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
| `GRPR-DBG-028` | Every register in § Register Map shall be readable over the debug port, by the `REG_READ` command of § Debug Port Commands. |
| `GRPR-DBG-039` | Register access shall be a debug-port operation only. `REG_READ` shall return the addressed register and `REG_WRITE` shall update the writable fields of `CTRL` and `DBGSEL` and shall service the write-1-to-clear bits of `STATUS`. No other path to these registers shall exist. |
| `GRPR-DBG-040` | A `REG_READ` or `REG_WRITE` shall be answerable whether or not a lock is active and whether or not the CPU is halted, and shall not be gated on `CTRL.LOCK_EN` or `CTRL.DBG_EN`. It reads and writes this block's own flops and touches neither bus, so nothing it needs can be held by a lock it is trying to diagnose. |
| `GRPR-DBG-041` | The block shall accept `REG_READ`/`REG_WRITE` without regard to which side of the transport originated them. Arbitration between a transport's own wire side and a CPU-sourced window access is the transport's responsibility — see `GRPR-SPIS-040`. |
| `GRPR-DBG-037` | The sticky `STATUS` bits (`REJECTED`, `BUS_ERR`, `STEP_DONE`), the `BUSADDR`/`BUSDATA`/`BUSERR` capture, and `STATUS.LOCK_MODE_ACT` shall retain their values across a lock release, and shall be cleared only by a write-1-to-clear or by reset. A debug session's outcome is therefore readable by a host after the fact, over the same transport that ran the session. |
| `GRPR-DBG-038` | *(Withdrawn.* There is no subordinate interface. `GRPR-DBG-040` carries the always-answerable property onto the debug port, which is where register access now lives.)* |
| `GRPR-DBG-029` | Reading debug state shall have no architectural side effects, and stepping shall have exactly the effect of the instructions executed and no other. |
| `GRPR-DBG-INFO-002` | The reset flavour is intended for the alternate boot path; the freeze flavour for interactive debug. `CTRL.LOCK_EN` and `CTRL.DBG_EN` are functional consent gates, **not** authentication. A host able to drive a debug transport can read and write all of ROM and RAM, drive any peripheral, and single-step the CPU. |
| `GRPR-DBG-INFO-003` | The CPU debug operations depend on CPU-side support — a register-file read port, a runtime reset vector, an instruction-retirement indication, and a program-counter output — that upstream picorv32 does not provide. See [Grouper SoC Specification § Debug/Test Features](../Grouper%20SoC%20Specification.md#debugtest-features). |

## Block Diagram

```
  ◀──────────────────── inside cpu_ss ────────────────────▶│◀─ outside ─▶
                                                           │
  ┌────────────┐  cpu_la_*  ┌─────┐                        │
  │  picorv32  ├───────────▶│     │                 ┌────▶ rom_*  ──▶ ROM
  │            │◀───────────┤ own │   mem_la_*  ┌───┴──┐  │
  │            │ mem_ready  │ mux ├────────────▶│decode│─┼──▶ ram_*  ──▶ RAM
  └──┬──────┬──┘  (gated)   │     │             │ +AHB │  │
     │      │               └──▲──┘             └───┬──┘  │
     │      │ trace,           │                    └────▶ H*  ──▶ AHB fabric
     │      │ PC, regs   dbg_own, dbg_req,           │    │
     │      │            dbg_addr/wdata/wstrb   dbg_ready │
     │      │                  │                 dbg_rdata│
     │      ▼               ┌──┴──────────────────────┐   │
     │  freeze, ◀───────────┤       Debug Unit        │   │
     └─ rst_req             │  ┌───────────────────┐  │   │
                            │  │ cmd FSM / lock    │  │   │
                            │  │ halt + step FSM   │  │   │
  transport ───────────────▶│  │ registers         │  │   │
  (SPI S, …)                │  └───────────────────┘  ├───┼──▶ dbg_lock_active
   dbg_req_* / dbg_rsp_*    └─────────────────────────┘   │      ──▶ io_ss pad-3 gate
        (brought out to the cpu_ss boundary, GRPR-DBG-042)         (GRPR-DBG-044,
                                                                      GRPR-GPIO-016)
```

The block sits **beside** the CPU inside `cpu_ss`, not in series with it and not
hanging off the fabric as a leaf peripheral. It has no port at the subsystem
boundary at all: what leaves `cpu_ss` is the same ROM port, RAM port and AHB
manager port it always drove, and the only boundary change is that the debug
port itself is now brought out for the transport to connect to
(`GRPR-DBG-042`).

There is **one** mux, not three, and it belongs to `cpu_ss` rather than to this
block (`GRPR-DBG-008`). It sits on picorv32's native look-ahead interface,
*upstream* of the ROM/RAM/bank-switch/AHB decode, so a debug request is decoded
and converted to AHB by exactly the logic that already serves the CPU. That is
why this block needs no AHB protocol logic of its own (`GRPR-DBG-002`) and no
second address decode (`GRPR-DBG-011`): it presents an address, strobes and
write data at the native level and the existing datapath does the rest.
Everything downstream — `periph_ss`, the interconnect, the memories — is
unchanged and cannot tell the two owners apart.

It has **neither a manager nor a subordinate port**. Its own registers are not
on the fabric and are reached over the debug port (`GRPR-DBG-039`), or by
firmware through the transport's register window
([`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)).
See `DBG-SPEC-003` for the timing consequence of the mux.

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
| `4'hA` | `REG_READ` | `addr[7:0]` = register offset; returns it in `rsp_rdata` |
| `4'hB` | `REG_WRITE` | `addr[7:0]` = register offset, `wdata` = value |
| `4'hC` | `DBG_ENABLE` | Sets `CTRL.LOCK_EN` and `CTRL.DBG_EN` together; no `addr`/`wdata` used |

Encodings `4'h9` and `4'hD`–`4'hF` are reserved; a request carrying one shall
be refused with `dbg_rsp_err`. `4'h9` was an arbitrary-execution-redirect
operation, removed for the reasons in `DBG-SPEC-002`; the encoding is left
vacant rather than reused, so a stale host issuing it gets a clean refusal
rather than a different operation. (`4'h8` is `RESUME`, listed above; earlier
revisions of this table gave `4'h8` in both roles, which was a defect.)

`DBG_ENABLE` exists so that a transport's wire-level enable opcode (for the
SPI Slave, `GRPR-SPIS-041`/`GRPR-SPIS-042`) has a normative effect on this
block's registers *through* the one debug-port protocol, rather than through a
side channel that bypasses it. Any transport wanting the same capability
issues the same command the same way — the SPI Slave's `LOCK`/`UNLOCK`/etc.
opcodes of [SPI Slave § Debug Command Encoding](SPI%20Slave%20Specification.md#debug-command-encoding)
follow the identical pattern, each a dedicated wire opcode mapping to one
`dbg_req_cmd`. It is answerable regardless of the current state of
`CTRL.LOCK_EN`/`DBG_EN` (setting them is the point), mirroring
`GRPR-DBG-040`'s always-answerable treatment of `REG_READ`/`REG_WRITE`.

`REG_READ`/`REG_WRITE` take a **register offset**, not a bus address: the
offsets of § Register Map, `0x00`–`0x24`. They are the only way to reach these
registers, the block having no subordinate port. An offset outside the table,
or a `REG_WRITE` to a read-only register, shall be refused with `dbg_rsp_err`.

`STATUS` is reachable two ways — `STATUS` (`4'h5`) returns it directly, and
`REG_READ` of offset `0x04` returns the same value. The dedicated command is
kept because it is the one a host issues before it knows anything else about
the block's state, and `GRPR-DBG-018` requires it to always work.

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

The block's own port list. Everything here is internal to `cpu_ss` except the
debug port, which `cpu_ss` passes straight through to its own boundary
(`GRPR-DBG-042`).

**Clock and reset**

| Port | Direction | Width | Description |
|---|---|---|---|
| `HCLK` / `HRESETn` | in | 1 / 1 | System clock and active-low reset. Named to match `cpu_ss`, which is where this block is instantiated |

**Debug port** — the transport-facing interface of § Debug Port Interface,
brought out through `cpu_ss` unchanged.

| Port | Direction | Width |
|---|---|---|
| `dbg_req_valid` / `dbg_req_ready` | in / out | 1 / 1 |
| `dbg_req_cmd` | in | 4 |
| `dbg_req_addr` | in | 32 |
| `dbg_req_wdata` | in | 32 |
| `dbg_req_size` | in | 2 |
| `dbg_rsp_valid` / `dbg_rsp_ready` | out / in | 1 / 1 |
| `dbg_rsp_rdata` | out | 32 |
| `dbg_rsp_err` | out | 1 |

**Lock-active indication** — also brought out to the `cpu_ss` boundary
(`GRPR-DBG-044`), for logic outside `cpu_ss` that needs to react to a lock
directly rather than by polling `STATUS`.

| Port | Direction | Width | Description |
|---|---|---|---|
| `dbg_lock_active` | out | 1 | Tracks `STATUS.LOCK_ACTIVE`. Consumed outside `cpu_ss` by the SPI Slave's pad-3 output-enable gate ([GPIO Mux `GRPR-GPIO-016`](GPIO%20Mux%20Specification.md)) |

**Bus request** — into and out of the `cpu_ss` ownership mux
(`GRPR-DBG-008`, `GRPR-DBG-043`). These are native-memory-interface signals, not
AHB.

| Port | Direction | Width | Description |
|---|---|---|---|
| `dbg_own` | out | 1 | The debug unit owns the bus this cycle. Selects the mux and gates the CPU's `mem_ready` |
| `dbg_req` | out | 1 | A transfer is being requested this cycle |
| `dbg_write` | out | 1 | 1 = write, 0 = read. With `dbg_req`, forms the mux'd read and write strobes |
| `dbg_addr` | out | 32 | Byte address, word-aligned. Decoded by `cpu_ss` as if it came from the CPU |
| `dbg_wdata` | out | 32 | Write data |
| `dbg_wstrb` | out | 4 | Byte strobes. Per picorv32's look-ahead convention these are also set on a read, where they select the size; a read is distinguished by `dbg_write` being 0 |
| `dbg_ready` | in | 1 | The requested transfer completed this cycle |
| `dbg_rdata` | in | 32 | Read data, valid with `dbg_ready` |
| `dbg_bus_error` | in | 1 | The completing transfer took an AHB error response (`GRPR-DBG-017`) |

**CPU control and observation** — to and from picorv32.

| Port | Direction | Width | Description |
|---|---|---|---|
| `cpu_freeze` | out | 1 | Stall the CPU (freeze-style lock, and between steps) |
| `cpu_rst_req` | out | 1 | Hold the CPU in reset (reset-style lock) |
| `cpu_retire` | in | 1 | One instruction retired — drives step counting |
| `cpu_pc` | in | 32 | Current program counter |
| `cpu_reg_sel` / `cpu_reg_data` | out / in | 5 / 32 | Register-file read port |
| `cpu_trace_valid` / `cpu_trace_data` | in | 1 / 36 | picorv32 trace stream |

**There is no AHB port of either kind.** The block is not a fabric slave and does
not appear in the address map, so `ahb_interconnect_ss` gains no slot for it and
its `SLOT_*` count is unchanged. Neither is it a fabric master: `cpu_ss` still
presents exactly one AHB manager port, driven by whichever owner the mux
selected, so the fabric sees one manager and needs no arbitration. The three
port groups `cpu_ss` drives in `hw/rtl/digital_ss.sv` — the AHB bundle
(`cpu_ss_ahb_s_if_*`), `rom_*`, and `ram_*` — keep their existing nets
untouched; only the debug port is added to that instantiation.

The bus-request group is named to match the `cpu_ss` internals it connects to:
`dbg_own`, `dbg_req`, `dbg_write`, `dbg_addr`, `dbg_wdata`, `dbg_wstrb`,
`dbg_ready`, `dbg_rdata` already exist there as the mux's debug-side arm.

### `cpu_ss` boundary change

`cpu_ss` gains the debug port and `dbg_lock_active`, and nothing else:

```systemverilog
  // Debug Request port (Slave) (GRPR-DBG-001).
  input  logic                      dbg_req_valid,
  output logic                      dbg_req_ready,
  input  logic [3:0]                dbg_req_cmd,
  input  logic [ADDR_WIDTH-1:0]     dbg_req_addr,
  input  logic [DATA_WIDTH-1:0]     dbg_req_wdata,
  input  logic [1:0]                dbg_req_size,
  output logic                      dbg_rsp_valid,
  input  logic                      dbg_rsp_ready,
  output logic [DATA_WIDTH-1:0]     dbg_rsp_rdata,
  output logic                      dbg_rsp_err,

  // Lock-active indication (GRPR-DBG-044), consumed by io_ss's pad-3 gate.
  output logic                      dbg_lock_active,
```

An earlier revision exposed the *mux* signals (`dbg_own`, `dbg_addr`, …) at the
`cpu_ss` boundary instead, expecting the debug unit to sit outside. Those are
now internal. `hw/rtl/digital_ss.sv` still ties off that older set and must be
updated to the port list above — until the transport is wired, tie
`dbg_req_valid` low and leave the response outputs unconnected, which holds
`dbg_own` low, leaves the mux a wire, and holds `dbg_lock_active` low.

## Register Access Protocol

Registers are reached over the debug port and nowhere else (`GRPR-DBG-039`).
This block has no AHB subordinate port, so no load or store lands *here*. A CPU
that wants its own debug state reaches these registers through the transport's
register window
([`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)),
which is an ordinary AHB access on the transport that becomes a `REG_READ` or
`REG_WRITE` on this port. The access is indirect, but it is a normal load or
store from firmware's point of view.

The handshake is the ordinary valid/ready pair of § Debug Port Interface. Both
directions handshake independently, so a slow transport can hold `rsp_valid`
asserted for as long as it needs.

The diagrams below are rendered with
[asciidrom](https://github.com/wipeseals/asciidrom) from WaveDrom sources. Signal
names are abbreviated (`req_valid` for `dbg_req_valid`, and so on); a bus row
shows `=-=` where the value changes and `===` while it is held, with the value
itself named in the row label, since the renderer carries no room for it in the
waveform.

**Two things can initiate one of these.** An external host framing a command on
the transport's wire, and the CPU accessing the transport's register window
([`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)).
Both arrive here as the same `REG_READ`/`REG_WRITE`, and this block does not
distinguish them (`GRPR-DBG-041`). `GRPR-DBG-005` allows one outstanding request,
so when both want the port at once someone must wait: that arbitration belongs to
the transport, which is the only place both sources are visible, and
`GRPR-SPIS-040` fixes the precedence — the wire side wins, because it is paced by
a clock this SoC does not drive.

### `REG_READ` — reading `STATUS` (offset `0x04`)

```
clk                 | _/¯¯\__/¯¯\__/¯¯\__/¯

request
  req_valid          | ____/¯¯¯¯¯\__________
  req_ready          | _______/¯¯\__________
  req_cmd   REG_READ | xxx=-=======xxxxxxxxx
  req_addr  0x04     | xxx=-=======xxxxxxxxx

response
  rsp_valid          | _____________/¯¯¯¯¯\_
  rsp_ready          | ________________/¯¯\_
  rsp_rdata STATUS   | xxxxxxxxxxxx=-====xxx
  rsp_err            | _____________________
```

`dbg_req_valid` and `dbg_req_addr` are held until `dbg_req_ready` is seen —
the transport may not withdraw a request the unit has not yet taken. The
response appears no earlier than the cycle after acceptance and is held until
`dbg_rsp_ready`. `GRPR-DBG-034` bounds the whole exchange at 2 `clk` cycles,
which the diagram shows as one cycle of accept latency and one of response.

### `REG_WRITE` — arming the consent gates in `CTRL` (offset `0x00`)

```
clk                  | _/¯¯\__/¯¯\__/¯¯\__/¯

request
  req_valid           | ____/¯¯¯¯¯\__________
  req_ready           | _______/¯¯\__________
  req_cmd   REG_WRITE | xxx=-=======xxxxxxxxx
  req_addr  0x00      | xxx=-=======xxxxxxxxx
  req_wdata 0x09      | xxx=-=======xxxxxxxxx

response
  rsp_valid           | __________/¯¯¯¯¯\____
  rsp_ready           | _____________/¯¯\____
  rsp_err             | _____________________

effect
  CTRL.LOCK_EN        | __________/¯¯¯¯¯¯¯¯¯¯
  CTRL.DBG_EN         | __________/¯¯¯¯¯¯¯¯¯¯
```

A write takes effect on acceptance, not on response consumption. `0x9` sets
`LOCK_EN` (bit 0) and `DBG_EN` (bit 3) together, which is the sequence a host
runs first on a chip whose boot ROM left the gates closed. The response carries
no data; only `dbg_rsp_err` is meaningful.

### A refused access

```
clk                  | _/¯¯\__/¯¯\__/¯¯\_

request
  req_valid           | ____/¯¯¯¯¯\_______
  req_ready           | _______/¯¯\_______
  req_cmd   REG_WRITE | xxx=-=======xxxxxx
  req_addr  0x10 (RO) | xxx=-=======xxxxxx

response
  rsp_valid           | __________/¯¯¯¯¯\_
  rsp_ready           | _____________/¯¯\_
  rsp_err             | __________/¯¯¯¯¯\_
  rsp_rdata           | xxxxxxxxxxxxxxxxxx
```

`BUSERR` is read-only, so the write is refused and `dbg_rsp_err` accompanies
the response. The register is unchanged and no other state moves — a refusal is
not an error condition in the block, only in the request. The same shape covers
an offset outside § Register Map.

### Diagnosing a refused lock from the host side

Register access sits on the debug port rather than the fabric so that a host
needs nothing but its own transport. The sequence for diagnosing a refused lock
shows why that matters:

```
clk                   | _/¯¯\__/¯¯\__/¯¯\__/¯¯\__/¯¯\_

1. LOCK, refused
  req_cmd   LOCK       | xxx=-=xxxxxxxxxxxxxxxxxxxxxxxx
  rsp_err              | _______/¯¯¯¯¯\________________

2. REG_READ STATUS
  req_cmd   REG_READ   | xxxxxxxxxxxxxxx=-=xxxxxxxxxxxx
  req_addr  0x04       | xxxxxxxxxxxxxxx=-=xxxxxxxxxxxx
  rsp_rdata REJECTED=1 | xxxxxxxxxxxxxxxxxxxxx=-=xxxxxx

block state
  STATUS.REJECTED      | _______/¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯
  STATUS.LOCK_ACTIVE   | ______________________________
```

The lock was refused, so the CPU is still running and the bus is undisturbed —
but the host has no bus access to read `STATUS` with, and asking the CPU to read
it for us is exactly the dependency `GRPR-DBG-013` and `GRPR-DBG-018` exist to
avoid. `REG_READ` closes the loop over the one interface a host is guaranteed
to have. `GRPR-DBG-040` is what makes this work: the read is not gated on the
consent bits it is trying to report.

Firmware runs the same exchange in the other direction — the same `REG_READ`,
reached by a load from the transport's register window rather than by framing a
command on the wire. Both arrive here identically.

## Register Map

| Offset | Name | Access | Reset | Purpose |
|---|---|---|---|---|
| 0x00 | CTRL | R/W | 0x0000_0000 | Consent gates and lock flavour |
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
| 2 | Reserved | - | Read 0, write 0. Was `TIMEOUT_EN` before `GRPR-DBG-016` was withdrawn; left vacant rather than reused, so a stale host arming a watchdog that no longer exists changes nothing else |
| 3 | DBG_EN | R/W | Permit CPU debug operations (read, step, resume) |
| 31:4 | Reserved | - | Read 0, write 0 |

`LOCK_EN` and `DBG_EN` are separate so a system can permit bus access without
permitting execution control, or the reverse.

Both reset to 0, unconditionally, with no exception — a chip is never seizable
out of reset. The boot ROM arms them in the normal case. Before it runs, or on
a chip whose ROM never runs, the only way to set them is the `DBG_ENABLE`
debug-port command (`4'hC`, § Debug Port Commands), reachable over the SPI
Slave transport's own wire-level `DBG_ENABLE` opcode regardless of any of that
transport's own register state
([`GRPR-SPIS-041`](SPI%20Slave%20Specification.md#debug-bus-access),
`GRPR-SPIS-042`) — see
[Grouper SoC Specification § Boot Flow](../Grouper%20SoC%20Specification.md#boot-flow),
`GRPR-SOC-030`, and `DBG-SPEC-001`. Firmware can clear them regardless of how
they were set (`GRPR-SOC-026`).

## STATUS — 0x04

| Bits | Field | Access | Description |
|---|---|---|---|
| 0 | LOCK_ACTIVE | RO | The debug unit currently owns the bus |
| 1 | LOCK_MODE_ACT | RO | Flavour of the current or most recent lock, latched at entry |
| 2 | LOCK_PENDING | RO | A lock has been accepted; handover is waiting on an in-flight CPU transfer |
| 3 | CPU_HALTED | RO | The CPU is stopped. Distinct from `LOCK_ACTIVE`, which is about bus ownership |
| 4 | Reserved | - | Read 0. Was `TIMEOUT`, withdrawn with the watchdog |
| 5 | REJECTED | W1C | A command was refused |
| 6 | BUS_ERR | W1C | A debug transfer took an error response or hit an unmapped address |
| 7 | STEP_DONE | W1C | A requested step count has completed |
| 31:8 | Reserved | - | Read 0 |

`CPU_HALTED` and `LOCK_ACTIVE` are deliberately independent. Bus ownership and
CPU execution state are separate concerns, and conflating them is how a lockout
becomes unreleasable.

The three W1C bits are sticky across a lock release (`GRPR-DBG-037`). That is
what makes them useful: a host that issues a command and gets a refusal can come
back afterwards and ask why, over the same transport, without needing the CPU to
be running or the bus to be free. Clearing them
is the host's job, by a `REG_WRITE` of the bits to clear — the block never
clears them on its own except at reset.

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

`DBGSEL` and the writable fields of `CTRL` are the only writable debug state,
reached by `REG_WRITE` (`GRPR-DBG-039`). Reading a general-purpose register is
therefore two debug-port operations: a `REG_WRITE` of `DBGSEL` to select the
index, then a `REG_READ` of `DBGREG`. `STATE_READ` with a selector in the
`0x10`–`0x1F` range does the same thing in one, and is what a host should
normally use; the register pair exists so the selected value is also visible in
a full register dump.

**When these are meaningful.** `DBGPC`, `DBGREG` and the trace registers report
CPU state captured while the CPU was halted, so they are meaningful only while
`STATUS.CPU_HALTED` is 1 or after a session that halted it. Firmware can read
them, through the transport's register window (`GRPR-SPIS-036`), but what it
reads is a post-mortem: a running CPU asking for its own `DBGPC` gets the value
captured when it was last halted, not where it is now. The firmware-only
breakpoint handler an earlier revision of this section described is therefore
still **not possible** — see `DBG-SPEC-009`.

There is deliberately **no CPU-facing control surface of any kind**, writable or
otherwise. The CPU already has the bus; a register file it could reach would add
verification burden and no capability.

## Clocking Strategy

| ID | Requirement |
|---|---|
| `GRPR-DBG-032` | The block shall be fully synchronous to `clk`, in a single clock domain. Any clock-domain crossing to a transport's own clock is the transport's responsibility, not this block's. |

## Reset Strategy

| ID | Requirement |
|---|---|
| `GRPR-DBG-033` | The block shall have an active-low reset, asynchronously asserted and synchronously de-asserted, consistent with the rest of the SoC. |

Reset releases any lock and returns bus ownership to the CPU (`GRPR-DBG-015`).
Because the block gates the CPU's reset and stall inputs, its own reset must
leave those deasserted, so that a reset never leaves the CPU stranded.

## CDC Strategy

Single clock domain; no crossing inside this block. The debug port is
synchronous to `clk`, so a transport in another domain must synchronise on its
side before presenting a request.

## Performance Targets

| ID | Requirement |
|---|---|
| `GRPR-DBG-034` | A debug-sourced word transfer to the AHB aperture shall complete in no more than 4 `clk` cycles plus whatever wait states the target subordinate inserts. A `REG_READ` or `REG_WRITE` shall complete in no more than 2, being a flop access with no bus involved. |
| `GRPR-DBG-035` | A debug-sourced word transfer to RAM shall complete in no more than 3 `clk` cycles, RAM being a fixed single-cycle target. |
| `GRPR-DBG-036` | Handover latency, from an accepted lock to `STATUS.LOCK_ACTIVE`, shall be bounded by the longest CPU transfer the fabric permits. |

## Size Estimate

TBD — not yet confirmed by synthesis. This block adds a register file, a command
FSM, and a step counter. It adds **no** AHB manager FSM (`GRPR-DBG-002`) and no
mux — the single mux is `cpu_ss` logic (`GRPR-DBG-008`) and costs a handful of
32-bit 2:1 selects on an existing path. For scale, the
`ahb_stub_slave` placeholders currently budget 1706 GE for the SPI Master slot
and 635 GE for the SPI Slave (`hw/rtl/periph_ss.sv`). An early `make measure-ge`
run is warranted before this specification is frozen — see `DBG-SPEC-004`.

## Open Items

- `DBG-SPEC-001` — **Resolved by the `DBG_ENABLE` wire opcode, superseding an
  earlier resolution by strap.** An earlier revision brought the consent gates
  up set out of reset when GPIO pad 15 was sampled high — a debug strap. That
  had an unresolved board-level defect: a floating pad 15 would arm debug by
  accident, and the pad's own programmable pull-down could not be established
  until firmware ran, which the strap exists to make optional. There was no
  clean way to close that loop, so the strap is **withdrawn** (`GRPR-SOC-024`,
  `-025` withdrawn) rather than patched.

  `CTRL.LOCK_EN` and `CTRL.DBG_EN` now reset to 0 unconditionally, with no
  pin-dependent exception. Cold-silicon reachability — the property the strap
  existed for — comes instead from the `DBG_ENABLE` debug-port command
  (`4'hC`), reachable because the SPI Slave transport decodes its own
  wire-level `DBG_ENABLE` opcode unconditionally, regardless of that
  transport's own register state
  ([`GRPR-SPIS-041`](SPI%20Slave%20Specification.md#debug-bus-access)). An
  external host sends `DBG_ENABLE` then `LOCK` with every gate closed and no
  firmware running, and needs no board-level pull-down because no pin is being
  sampled — see `GRPR-SOC-030`. GPIO pads 0–2 defaulting to the SPI-slave
  alternate function at reset (`GRPR-SOC-027`) is what makes the command
  reachable at all before firmware runs; pad 3 (`MISO`) also defaults to the
  alternate function but does not drive until `dbg_lock_active` asserts
  (`GRPR-DBG-044`, `GRPR-SOC-028`), so the host cannot observe a response to
  `DBG_ENABLE` itself — only to the `LOCK` that follows it
  (`GRPR-SPIS-043`).
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
- `DBG-SPEC-003` — **The mux is on the critical path.** Moving the mux onto the
  native look-ahead interface upstream of the decode (`GRPR-DBG-008`) reduced
  this from three muxes to one, but did not remove it: `mem_la_addr` feeds the
  address decode, which feeds the ROM/RAM strobes, and the RAM path is already
  the long combinational path in the design
  ([`GRPR-SOC-008`](../Grouper%20SoC%20Specification.md#interconnect-architecture)).
  The mux must stay combinational and thin. A registered mux would break
  `cpu_ss`'s single-cycle RAM assumption and require that logic reworked. The
  `dbg_own` term also now gates `cpu_mem_ready` and appears in the bank-switch
  compare, so it wants to be a flop output of this block, not a combinational
  function of the incoming request.
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

- `DBG-SPEC-008` — **Resolved: the peripheral aperture is reachable, without an
  AHB port here.** An earlier revision removed the block's AHB manager port,
  which cost access to the peripheral aperture and contradicted `GRPR-DBG-011`;
  the revision after that restored the port and put the block in series at the
  subsystem boundary. Both are superseded. Muxing on the native look-ahead
  interface upstream of the decode (`GRPR-DBG-008`) reaches the whole map —
  ROM, RAM, bank switch and the AHB aperture — while the block itself keeps no
  AHB logic at all, which is strictly less to build and to verify than either
  earlier arrangement.
  Note this is what gives the dedicated `BUS_WRITE`/`BUS_READ` opcodes their
  reach: a full 32-bit address landing anywhere an AHB manager port of this
  block's own would have reached, peripherals included. The SPI Slave's legacy
  APS6404L data commands are not a second, narrower tier of the same path —
  they never touch the debug port at all (`GRPR-SPIS-030`, `-031`, both
  withdrawn) and terminate in that transport's own FIFOs, so their 24-bit
  addressing is a property of the APS6404L command set they emulate and says
  nothing about what the debug unit can reach.
- `DBG-SPEC-009` — **Mostly resolved by the transport's register window.**
  Removing the subordinate port left firmware unable to see any debug state,
  which contradicted `GRPR-SOC-023` (the boot ROM must *arm* `CTRL.LOCK_EN`) and
  `GRPR-SOC-026` (firmware must be able to *revoke* strap-armed access — a
  security property, not a convenience). The window of
  [`GRPR-SPIS-036`](SPI%20Slave%20Specification.md#debug-unit-register-window)
  restores both: firmware reaches `CTRL`, `STATUS`, and the bus-error capture
  through the SPI Slave's aperture, without this block gaining a port and
  without firmware gaining a command surface.

  What remains open is narrower. A **firmware-only breakpoint handler** reading
  `DBGREG` against its own live register file is still not possible: `DBGREG`
  reports state captured while the CPU was halted, so a running CPU reading it
  learns nothing about itself. That needs a register-file read port that works
  on an unhalted CPU, which is a `cpu_ss` change, not a change here. And the
  window depends on a transport being present and built — a configuration with
  `DEBUG_PORT_EN` deasserted has no path to these registers at all.
- `DBG-SPEC-010` — **Withdrawing the watchdog removes the only recovery from an
  abandoned lock.** With `GRPR-DBG-016` gone, a lock ends by explicit release or
  by reset, and nothing else. If a host takes a reset-style lock and then
  disappears — cable pulled, host crashed — the CPU stays held in reset with no
  software able to intervene, because a locked-out CPU cannot run the firmware
  that would clear the gate. Recovery is then a power cycle or an external reset
  assertion.

  That is acceptable for a debug-bench part and is the reason the watchdog was
  specified in the first place, so the trade is worth restating rather than
  forgetting: the watchdog cost a counter, a comparator, and a configuration
  field, and it bought unattended recovery. If a deployment ever needs a
  GrouperSoC to survive an abandoned debug session without physical access, this
  requirement has to come back. `CTRL` bit 2 and `STATUS` bit 4 are left vacant
  against that possibility.
- `DBG-SPEC-011` — **CPU internal state is not observable without a CPU fork.**
  This is the largest functional gap in the block as built, and it is worth
  stating plainly rather than leaving implicit in `GRPR-DBG-INFO-003`: of the
  three things a debugger most wants from a halted CPU — the program counter,
  the register file, and the retired-instruction record — **only the third is
  available**, and only because `ENABLE_TRACE` is on.

  What is refused today, in `hw/rtl/debug/dbg_ctrl.sv`:

  | Selector / register | Status | Why |
  |---|---|---|
  | `SEL_PC` (`0x00`), `DBGPC` (`0x14`) | **Refused** (`sel_valid` excludes it; `REG_DBGPC` reads 0) | picorv32 exposes no `reg_pc` output. The trace record carries a *branch target* or a load/store effective address, never the PC of the instruction that retired, so it cannot stand in for one without reporting a wrong value that looks right. |
  | `SEL_REG_0..15` (`0x10`–`0x1F`), `DBGREG` (`0x20`) | **Refused** (`dbg_rsp_err`) | No register-file read port. `cpuregs` is internal to picorv32 and has no external read path. |
  | `SEL_TRACE_LOW` (`0x01`), `SEL_TRACE_FLAGS` (`0x02`), `DBGTRACE`/`DBGTRACEH` | **Available** | `trace_valid`/`trace_data`, gated on the core being built with `ENABLE_TRACE`. |

  The consequence for `GRPR-DBG-023` is that the requirement is only partly
  met: a state read returns the trace record, but the program counter and
  general-purpose registers named in the same requirement are unobtainable. A
  host can halt the CPU, single-step it, and watch memory change — but cannot
  see *where* it is executing or what is in its registers, which is what makes
  a stepped debug session interpretable. In practice a debugger must infer
  position from the trace record's branch targets and from memory side
  effects.

  Closing this needs four CPU-side additions, all in the team's picorv32 fork
  (`ip/picorv32/`), none of them available upstream:

  1. a `reg_pc` output, for `SEL_PC`/`DBGPC`;
  2. a register-file read port that works while the core is halted, for
     `SEL_REG_*`/`DBGREG` — and, separately, one that works while it is
     *running* if the firmware-breakpoint case of `DBG-SPEC-009` is ever
     wanted;
  3. a retirement indication that does not depend on `ENABLE_TRACE`, so trace
     can be dropped for area without also removing `STEP` (this is
     `DBG-SPEC-006`, which this item subsumes for the state-read half);
  4. a runtime-writable reset vector, if the redirect of `DBG-SPEC-002` is
     ever reopened.

  Items 1 and 2 are the ones that block `GRPR-DBG-023`. Both are additive to
  picorv32 — read ports and an output, no change to its control FSM — but they
  are a CPU change and therefore a fork commitment, with the resynthesis and
  regression cost that implies. Until they land, `GRPR-DBG-023` should be read
  as *trace-record only*, and the verification plan's coverage of it is
  correspondingly partial (`V-DBG-DIR-027`, `-028`).

  **This is not observable in silicon by any other route.** There is no scan
  path to the register file in the current floorplan, and the debug unit
  deliberately owns no AHB port of its own (`GRPR-DBG-002`), so nothing in the
  memory map aliases CPU internal state. A gate-level or post-silicon debug
  session has exactly the same limitation as simulation.
- `DBG-SPEC-012` — **A lock and a debug transfer are different windows, and
  `GRPR-DBG-043` means the narrower one.** `dbg_own` is `STATUS.LOCK_ACTIVE`
  for the whole lock, but `STEP` (`GRPR-DBG-025`) and `RESUME`
  (`GRPR-DBG-027`) both clear `cpu_freeze` while the lock is still held — the
  CPU is *meant* to execute during part of a lock. An earlier `cpu_ss`
  implementation keyed both the ownership mux and `cpu_mem_ready` on
  `dbg_own`, which made those two operations unusable:

  - the mux pointed `mem_la_*` at the debug port even when it was not
    requesting anything, so the CPU's own fetches and stores never reached
    memory;
  - `cpu_mem_ready = mem_ready && !cpu_freeze` nonetheless told the CPU those
    transfers had completed, handing it `mem_rdata` belonging to the debug
    port.

  picorv32 retired whatever that held. Observed at the SoC level as the
  program counter collapsing out of the running firmware loop within ~2.6 µs
  of a `RESUME` issued before `UNLOCK`, after which the CPU never executed
  the program again — a silent corruption of `GRPR-DBG-020`'s
  state-preservation guarantee, triggered by the ordering `GRPR-DBG-027`
  explicitly permits.

  Both are now keyed on `dbg_own && dbg_req` — the debug unit's actual
  transfer. Exclusivity is unchanged: the debug unit wins every cycle it wants
  the bus, and the CPU stalls mid-transfer with architectural state intact,
  exactly as under a freeze. Keying on `dbg_own` instead would stall the CPU
  for the entire lock, and `STEP` could never retire anything.

  The requirement text of `GRPR-DBG-043` should be read accordingly, and
  `V-DBG-CHK-033` updated: the property is *no CPU transfer completes while a
  debug transfer is in flight*, not *the CPU is stalled for the whole lock*.
  The two are only the same under a freeze-flavour lock that is never stepped
  or resumed, which is why the distinction went unnoticed.
## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-DBG-001` | `V-DBG-CHK-001` (negative check: no port of this block reaches the `cpu_ss` boundary except the debug port) |
| `GRPR-DBG-002` | `V-DBG-CHK-002` (negative check: no AHB port of either kind, no fabric slot) |
| `GRPR-DBG-042` | `V-DBG-CHK-031` (debug port present and connected at the `cpu_ss` boundary) |
| `GRPR-DBG-003` | `V-DBG-CHK-003` (exactly one port present) |
| `GRPR-DBG-004` | `V-DBG-CHK-029` (negative check: no selection or priority logic exists) |
| `GRPR-DBG-005` | `V-DBG-CHK-004` |
| `GRPR-DBG-006` | `V-DBG-CHK-005` (assertion: never two non-IDLE sources), `V-DBG-DIR-011` |
| `GRPR-DBG-007` | `V-DBG-STM-004`, `V-DBG-CHK-006`, `V-DBG-DIR-009` |
| `GRPR-DBG-008` | `V-DBG-CHK-007`, `V-DBG-DIR-011` (mux verified at `cpu_ss` level, the block having no port group of its own) |
| `GRPR-DBG-043` | `V-DBG-CHK-033` (`cpu_mem_ready` low whenever a debug transfer is in flight — `dbg_own && dbg_req`, not `dbg_own` alone; see `DBG-SPEC-012`), `V-DBG-DIR-035` |
| `GRPR-DBG-044` | `V-DBG-CHK-034` (`dbg_lock_active` asserts the same cycle `STATUS.LOCK_ACTIVE` does, brought out to the `cpu_ss` boundary), `V-DBG-DIR-036` (`DBG_ENABLE` sets `LOCK_EN`+`DBG_EN`; refused-encoding check on the remaining vacant slots) |
| `GRPR-DBG-009` | `V-DBG-STM-005`, `V-DBG-CHK-008`, `V-DBG-DIR-010` |
| `GRPR-DBG-010` | `V-DBG-STM-006`, `V-DBG-CHK-009`, `V-DBG-DIR-014` |
| `GRPR-DBG-011` | `V-DBG-STM-007`, `V-DBG-COV-001`, `V-DBG-DIR-015` (ROM, RAM, bank switch and the peripheral aperture all reachable — see `DBG-SPEC-008`) |
| `GRPR-DBG-012` | `V-DBG-STM-008`, `V-DBG-DIR-016` |
| `GRPR-DBG-013` | `V-DBG-CHK-010`, `V-DBG-DIR-008`, `-012`, `-013` |
| `GRPR-DBG-014` | `V-DBG-STM-009`, `V-DBG-DIR-018` |
| `GRPR-DBG-015` | `V-DBG-STM-010`, `V-DBG-CHK-011`, `V-DBG-DIR-019` |
| `GRPR-DBG-016` | *(withdrawn — no verification items)* |
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
| `GRPR-DBG-028` | `V-DBG-STM-019`, `V-DBG-DIR-001`, `-006` (every offset readable by `REG_READ`) |
| `GRPR-DBG-039` | `V-DBG-DIR-033` (`REG_READ`/`REG_WRITE` round trip), `V-DBG-CHK-032` (no other path to the registers) |
| `GRPR-DBG-040` | `V-DBG-DIR-034` (answered with a lock active, the CPU halted, and both consent gates clear) |
| `GRPR-DBG-037` | `V-DBG-STM-021`, `V-DBG-CHK-030`, `V-DBG-DIR-004`, `-006` |
| `GRPR-DBG-038` | *(withdrawn — see `GRPR-DBG-040`)* |
| `GRPR-DBG-029` | `V-DBG-CHK-023`, `V-DBG-DIR-027` |
| `GRPR-DBG-030` | `V-DBG-CHK-024` (no port-count parameter exists) |
| `GRPR-DBG-031` | *(parameter range — elaboration-checked)* |
| `GRPR-DBG-032` | `V-DBG-CHK-025` |
| `GRPR-DBG-033` | `V-DBG-STM-010`, `V-DBG-CHK-011`, `V-DBG-DIR-019` |
| `GRPR-DBG-034` | `V-DBG-CHK-026` (register access completes within 2 `clk`) |
| `GRPR-DBG-035` | `V-DBG-CHK-027` |
| `GRPR-DBG-036` | `V-DBG-CHK-028` |

See [Debug Unit Verification Plan](../../verification/blocks/Debug%20Unit%20Verification%20Plan.md)
for the full item definitions and test list.
