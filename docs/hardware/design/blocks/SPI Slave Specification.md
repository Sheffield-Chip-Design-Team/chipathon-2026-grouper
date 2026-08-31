# AHB SPI Slave

**Owner:** Thiri
**Status:** RTL in progress — `hw/rtl/spi_s/ahb_spi_s.sv` exists and is instantiated in `hw/rtl/periph_ss.sv`. The register interface and the byte shift path work; the command FSM is partially implemented, and the debug port of this document is specification only.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence, memory map | [Debug Unit](Debug%20Unit.md) — the block this one's debug port connects to | [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md)

---

## Purpose

SPI slave interface that lets an external SPI host talk to GrouperSoC. The
block presents an APS6404L-compatible command interface *to* that host, so a
controller which already speaks the PSRAM SPI protocol needs no bespoke
protocol to exchange data with firmware.

It also serves as the SoC's first **debug transport**. Under the
`DEBUG_PORT_EN` parameter, a dedicated set of wire opcodes (§ Debug Command
Encoding) moves bytes between the wire and the SoC memory map, reached over
the debug port of the [Debug Unit](Debug%20Unit.md), which is the block that
actually masters the bus. The APS6404L data commands (`SPI_READ`/`SPI_WRITE`/
`FAST_READ`/`FAST_WRITE`) are unaffected by any of this — they always talk to
this block's own FIFOs, in every build. This block frames and forwards; it
does not master any bus, hold CPU state, or decide whether an access is
permitted.

## Protocols / Standards Conformity

| ID              | Requirement                                                                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-001` | The block shall feature an AHB-Lite subordinate interface on the CPU side.                                                                           |
| `GRPR-SPIS-002` | THe block shall feature Motorolas SPI slave interface on the external side: CPOL/CPHA mode 0/3, MSB-first transfer on MISO.                          |
| `GRPR-SPIS-003` | The SPI command set shall be taken from the APS6404L datasheet's SPI-mode commands.                                                                  |

## Key Functionality

| ID              | Requirement                                                                                                           |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-004` | The block shall receive and transmit data over the SPI interface, with that data accessible through the AHB-Lite bus. |
| `GRPR-SPIS-005` | The block shall support `SPI_READ`, `FAST_READ`, `SPI_WRITE`, and `FAST_WRITE` commands.                              |
| `GRPR-SPIS-006` | The block shall occupy a 4 KiB region of the AHB peripheral aperture, containing two decoded sub-apertures: its own registers at offset `0x000`, and the Debug Unit register window of `GRPR-SPIS-036` at offset `0x100`. |

### Buffering and Interrupts

Added so the block can meet `GRPR-SPIS-013` (one payload byte every 2 µs)
without a per-byte AHB round trip, and so a missed deadline is reported rather
than silently losing data. See § Buffered Data Path for the rationale.

| ID              | Requirement                                                                                                                                                                                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-023` | The receive path shall buffer bytes in a FIFO whose depth is set by a `FIFO_DEPTH` parameter, defaulting to 4. The depth shall be a power of two and shall be checked at elaboration, so an unsupported value fails the build rather than mis-synthesising.                                                     |
| `GRPR-SPIS-024` | The transmit path shall buffer bytes in a FIFO of the same `FIFO_DEPTH`, subject to the same constraint.                                                                                                                                                                                                       |
| `GRPR-SPIS-025` | A read of `RXDATA` shall pop one byte per asserted `HSIZE` byte lane, **low lane first**, so a 32-bit read returns four received bytes packed into one word. A read that requests more bytes than the FIFO holds shall return the bytes available, zero the remaining lanes, and set `IRQ_STATUS.UNDERFLOW`.     |
| `GRPR-SPIS-026` | A write to `TXDATA` shall queue one byte per asserted `HSIZE` byte lane, **low lane first**, so a 32-bit write queues four bytes for transmission. A write to a full TX FIFO shall drop the surplus lanes and set `IRQ_STATUS.OVERFLOW`.                                                                        |
| `GRPR-SPIS-027` | The block shall hold `HREADYOUT` low while a multi-lane `TXDATA` or `RXDATA` access drains, so it completes as a single AHB transfer. The stall shall be bounded by the lane count — at most 3 wait states for a 32-bit access — and shall never be paced by the SPI wire.                                       |
| `GRPR-SPIS-028` | The block shall provide a write-1-to-clear `IRQ_STATUS` register separating in-transfer (wire-side) FIFO events from AHB access errors, so firmware can tell a missed SPI deadline from its own mis-sized bus access.                                                                                           |
| `GRPR-SPIS-029` | The block shall provide an `IRQ_EN` register with a per-source enable at each `IRQ_STATUS` bit position, and an `irq` output asserted when any enabled source is set.                                                                                                                                           |

### Debug Port

The block's role here is transport only. Everything about bus mastering,
ownership, and CPU control belongs to the [Debug Unit](Debug%20Unit.md).

| ID                   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-014`      | The block shall provide an optional debug port, instantiated under the `DEBUG_PORT_EN` parameter, presenting decoded debug commands on the debug-port interface defined in [Debug Unit § Debug Port Interface](Debug%20Unit.md#debug-port-interface). When the parameter is deasserted the port and its logic shall be absent, and the block's behaviour and register map shall be identical to a build without this feature. |
| `GRPR-SPIS-015`      | The block shall translate each dedicated debug opcode of § Debug Command Encoding into one or more requests on the debug port, per that section's framing. It shall not itself interpret addresses, master any bus, or hold CPU state.                                                                                                                                                                                                               |
| `GRPR-SPIS-016`      | *(Withdrawn along with `GRPR-SPIS-030`.* There is no retargeting register bit to gate any more; `SPI_READ`/`SPI_WRITE`/`FAST_READ`/`FAST_WRITE` always use the FIFO data path. Whether a dedicated debug opcode's forwarded request is honoured remains the Debug Unit's decision, not this block's — see `GRPR-DBG-007`.)* |
| `GRPR-SPIS-017`      | The block shall present at most one debug request at a time, and shall hold SPI-side pacing — stalling the response bytes of a read — until the response arrives or the transaction is aborted.                                                                                                                                                                                                                               |
| `GRPR-SPIS-018`      | Deassertion of `SS` mid-command shall abort that command at the transport level without leaving the debug port mid-handshake. It shall **not** by itself release a lock or resume the CPU; those persist until an explicit command, per `GRPR-DBG-014`.                                                                                                                                                                       |
| `GRPR-SPIS-019`      | `CTRL.SOFT_RESET` shall reset the SPI command FSM and abort any outstanding debug request, without altering any Debug Unit state. Note this is an AHB register write and so is unavailable while the CPU is halted; `GRPR-SPIS-022` provides the equivalent recovery from the SPI side.                                                                                                                                       |
| `GRPR-SPIS-022`      | Deassertion of `SS` shall return the command decoder to its idle state unconditionally, so that an external host can always resynchronise by raising `SS` and starting a new transaction. This shall hold regardless of how far through a command the block had progressed, and shall not depend on any AHB access.                                                                                                           |
| `GRPR-SPIS-030`      | *(Withdrawn.* `SPI_READ`/`SPI_WRITE`/`FAST_READ`/`FAST_WRITE` are never retargeted to the debug port; they always run through the RX/TX FIFOs, unconditionally, and the register bit that once gated retargeting (`CTRL.DEBUG_PORT_EN`) is removed. All debug bus access goes through the dedicated opcode set of § Debug Command Encoding instead. See `SPIS-SPEC-010`.)* |
| `GRPR-SPIS-031`      | *(Withdrawn along with `GRPR-SPIS-030`.* The legacy commands' 24-bit address never reached the debug port at all, so there is no reach limit to state about them. `BUS_READ`/`BUS_WRITE` of § Debug Command Encoding carry a full 32-bit address and reach the whole memory map, peripherals included.)* |
| `GRPR-SPIS-032`      | While a dedicated debug opcode of § Debug Command Encoding is framing a data phase, those bytes shall bypass the RX and TX FIFOs entirely, and shall neither set nor be affected by `IRQ_STATUS.OVERRUN`/`UNDERRUN`. |
| `GRPR-SPIS-033`      | A debug request that returns `dbg_rsp_err`, or that is never accepted, shall not hang the SPI side. `SS` deassertion shall always recover the block (`GRPR-SPIS-022`). |
| `GRPR-SPIS-034`      | A multi-byte `BUS_WRITE`/`BUS_READ` burst shall auto-increment the address by one per payload byte, satisfying `GRPR-DBG-012`. A write shall advance on each received byte; a read shall advance on each accepted `dbg_req` handshake, since the bus paces reads rather than `SCK`. |
| `GRPR-SPIS-035`      | With the `DEBUG_PORT_EN` build parameter deasserted, the dedicated debug opcodes of § Debug Command Encoding are entirely absent and every wire opcode behaves as a build without this feature — there being no legacy-opcode retargeting any more (`GRPR-SPIS-030`), this is the only configuration difference `DEBUG_PORT_EN` makes. |
| `GRPR-SPIS-INFO-001` | The debug port is transport-neutral. This block's wire framing is the APS6404L command set plus the dedicated opcodes of § Debug Command Encoding; a JTAG or UART transport would use its own framing over the same port. |

## Debug Bus Access

Present only when the `DEBUG_PORT_EN` build parameter is set. `SPI_READ`/
`SPI_WRITE`/`FAST_READ`/`FAST_WRITE` are **not** part of this — they always use
the RX/TX FIFOs, unconditionally, in every build (`GRPR-SPIS-030`, withdrawn).
All debug bus access goes through the dedicated opcode set of
§ Debug Command Encoding below, which reaches the Debug Unit's entire command
surface: lock, release, status, state read, step, resume, and a
32-bit-addressed read/write pair.

### `DBG_ENABLE` — decoded before anything else

| ID | Requirement |
| --- | --- |
| `GRPR-SPIS-041` | The block shall decode a dedicated single-byte wire opcode, `DBG_ENABLE` (`0x55`), unconditionally: regardless of `CTRL.ENABLE` or any other register state, mirroring the unconditional-recovery precedent of `GRPR-SPIS-022`. The opcode carries no address or data phase. |
| `GRPR-SPIS-042` | On completing receipt of `DBG_ENABLE`, the block shall issue the Debug Unit's `DBG_ENABLE` debug-port command ([`4'hC`](Debug%20Unit.md#debug-port-commands)), which sets `CTRL.LOCK_EN` and `CTRL.DBG_EN` together. It shall not, as part of this opcode, affect pad 3's output enable — that follows only from a subsequent `BUS_LOCK` being accepted ([`GRPR-DBG-044`](Debug%20Unit.md#bus-mastering-and-ownership)). |
| `GRPR-SPIS-043` | `DBG_ENABLE` shall produce no response on `MISO` distinguishable from idle, since pad 3 is not yet driving (`GRPR-GPIO-016`). The intended host protocol is fire-and-forget: a host sends `DBG_ENABLE`, then sends `BUS_LOCK`, and treats a genuine, driven response to `BUS_LOCK` as its confirmation that the earlier `DBG_ENABLE` succeeded. There is no acknowledgement to `DBG_ENABLE` itself. |

`DBG_ENABLE` carries nothing to reuse — its entire purpose is to run before
`CTRL.LOCK_EN`/`CTRL.DBG_EN` are armed, when nothing else has granted debug
access yet. It has to be its own wire-level opcode, decoded by the command
FSM directly, exactly like every other opcode in § Debug Command Encoding.

`GRPR-SPIS-041`'s unconditional decode is what makes this useful for
cold-silicon access (`GRPR-SOC-030`): the Debug Unit's own consent gates
(`CTRL.LOCK_EN`, `CTRL.DBG_EN`) reset to 0 (`GRPR-SOC-029`), so nothing else
in a freshly-reset chip can arm them — `DBG_ENABLE` reaches the Debug Unit
unconditionally, the same way `GRPR-SPIS-022`'s `SS`-deassertion recovery does
not consult any register either.

### Debug Command Encoding

The rest of the Debug Unit's command surface — lock, release, status, state
read, step, resume, and a full-width read/write pair — has no framing in the
legacy APS6404L opcodes, so each gets its own dedicated wire opcode, decoded
the same unconditional way `DBG_ENABLE` is (`GRPR-SPIS-041`'s treatment,
generalised): once the `DEBUG_PORT_EN` build parameter is set, with no
register-level gate at all. This lets a host recover a locked CPU with
`BUS_UNLOCK` regardless of any other register state, and keeps every debug
opcode consistent about what it depends on.

| ID | Requirement |
| --- | --- |
| `GRPR-SPIS-044` | The block shall decode the dedicated single-byte wire opcodes of § Debug Command Encoding Table unconditionally (the same treatment as `DBG_ENABLE`, `GRPR-SPIS-041`), each translating to exactly one request on the debug port per the mapping given. |
| `GRPR-SPIS-045` | `BUS_WRITE` and `BUS_READ` shall carry a **32-bit** address phase, MSB-first, distinct from the legacy commands' 24-bit phase. The address is presented to the debug port unmodified, reaching the full CPU memory map including the AHB peripheral aperture (bit 31). |
| `GRPR-SPIS-046` | `BUS_READ` and `DBG_READ` shall each insert exactly one dummy byte after their address/selector phase before the first response byte, covering the debug-port round trip latency (`GRPR-DBG-034`). |
| `GRPR-SPIS-047` | `BUS_LOCK`'s one payload byte shall map to the `LOCK` debug-port command's `wdata`: bit 0 is the requested `LOCK_MODE` override and bit 8 does not fit in a single byte, so this transport always presents `wdata[8]` (the override-valid flag) as 1 — a `BUS_LOCK` byte always supplies an explicit mode, it cannot request "use whatever `CTRL.LOCK_MODE` already holds". |
| `GRPR-SPIS-048` | Opcode `0x56` is reserved and shall be refused (produce no debug-port request and no `MISO` response) rather than decoded. It carried an arbitrary-execution-redirect command in an earlier draft, removed per [Debug Unit `DBG-SPEC-002`](Debug%20Unit.md#open-items); the encoding is left vacant rather than reused so a stale host gets a clean refusal. |

#### Debug Command Encoding Table

| Opcode | Name | Phases after opcode | Debug-port command |
| --- | --- | :--- | --- |
| `0x51` | `BUS_WRITE` | 32-bit address + N data bytes | `WRITE` (`4'h4`) |
| `0x52` | `BUS_READ` | 32-bit address + 1 dummy byte + N data bytes | `READ` (`4'h3`) |
| `0x53` | `BUS_STATUS` | 1 dummy byte + 4 status bytes | `STATUS` (`4'h5`) |
| `0x54` | `DBG_READ` | 1 selector byte + 1 dummy byte + 4 data bytes | `STATE_READ` (`4'h6`) |
| `0x55` | `DBG_ENABLE` | none | `DBG_ENABLE` (`4'hC`) — see § `DBG_ENABLE` above |
| `0x57` | `DBG_RESUME` | none | `RESUME` (`4'h8`) |
| `0x58` | `DBG_STEP` | 1 count byte | `STEP` (`4'h7`) |
| `0x5A` | `BUS_LOCK` | 1 flags byte | `LOCK` (`4'h1`) |
| `0xA5` | `BUS_UNLOCK` | none | `UNLOCK` (`4'h2`) |

None of these opcodes alias a real APS6404L command, nor each other, nor the
legacy four. `BUS_LOCK` (`0x5A`) and `BUS_UNLOCK` (`0xA5`) are bitwise
complements, giving them a Hamming distance of 8, so no single-bit error on
`MOSI` can turn a release into a bus seizure. `DBG_STEP` uses `0x58` rather
than the classic `0x55` bus-test pattern an earlier draft assigned it, because
`0x55` is now `DBG_ENABLE`.

`REG_READ`/`REG_WRITE` are deliberately **not** in this table: register access
stays AHB-window-only, per § "What this does not give firmware" below —
firmware and an external host reach the register file the same way, and
neither gets a second path to it.

### Reaching peripherals and CPU control

`BUS_WRITE`/`BUS_READ`'s 32-bit address phase reaches the full memory map,
including the AHB peripheral aperture, so `SPIS-SPEC-014`'s prior limit no
longer applies. The legacy `SPI_WRITE`/`SPI_READ`/`FAST_WRITE`/`FAST_READ`
commands never reach the debug port at all any more (`GRPR-SPIS-030`,
withdrawn) — they keep their 24-bit, FIFO-only APS6404L behaviour
unconditionally, and a host wanting debug access of any kind, RAM/ROM
included, uses `BUS_WRITE`/`BUS_READ` instead.

### Releasing a lock, and recovering from a wedged command

A lock taken with `BUS_LOCK` is released with `BUS_UNLOCK` over the same SPI
link — that is the normal path, and it works whether or not the CPU is
halted, since the CPU plays no part in it (`GRPR-DBG-013`). If a command is
interrupted or the host loses track of where it is in a phase, raising `SS`
returns this block's decoder to idle (`GRPR-SPIS-022`) without disturbing the
lock, so the host can simply start a fresh transaction and issue
`BUS_UNLOCK`. `CTRL.SOFT_RESET` does the same thing but is an AHB write, so it
is *not* available while the CPU is halted — `SS` deassertion is the SPI-side
equivalent and the one a host should rely on.

### Aborting

`SS` deassertion returns the decoder to idle without leaving the debug port
mid-handshake (`GRPR-SPIS-018`, `GRPR-SPIS-022`). It does not disturb any
Debug Unit state, including an active lock.

### Effect of the `DEBUG_PORT_EN` build parameter

The legacy four commands (`SPI_WRITE`/`SPI_READ`/`FAST_WRITE`/`FAST_READ`)
behave identically whether or not `DEBUG_PORT_EN` is set — they never touch
the debug port (`GRPR-SPIS-030`, withdrawn). `DBG_ENABLE` and the opcodes of
§ Debug Command Encoding exist only when `DEBUG_PORT_EN` is set
(`GRPR-SPIS-035`); when it is, they decode unconditionally, with no register
bit gating them (`GRPR-SPIS-041`, `GRPR-SPIS-044`).

## Block Diagram

Main blocks: Shift Register, Register Bank, AHB Bus Logic, Command FSM Control,
and — under `DEBUG_PORT_EN` — a Debug Port adapter that turns a decoded debug
command into one request on the Debug Unit's port.

```
  



```

The firmware-load path is **not** a separate datapath in this block: an
external host loads firmware by issuing debug commands, which the Debug Unit
turns into RAM writes. See [Debug Unit § Purpose](Debug%20Unit.md#purpose).

## uARCH Diagram

TODO


## Parameters and Configurations

| ID              | Requirement                                                                                                                                                                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-007` | The block shall support byte-granular SPI transfers rather than requiring full-word bursts.                                                                                                                                                                                                        |
| `GRPR-SPIS-008` | All block state shall be observable and controllable through the documented register map, with no side-channel paths.                                                                                                                                                                              |
| `GRPR-SPIS-020` | The `DEBUG_PORT_EN` *parameter* shall select whether the debug port of `GRPR-SPIS-014` is instantiated, and shall default to disabled. There is no corresponding register bit — a build with the parameter set decodes the debug opcodes of § Debug Command Encoding unconditionally at run time (`GRPR-SPIS-041`, `GRPR-SPIS-044`); a build without it has neither the opcodes nor the port. |

## IOs and External Interfaces

| Port                                                                    | Direction | Width | Description                                                                                                                          |
| ----------------------------------------------------------------------- | --------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `HCLK` / `HRESETn`                                                      | in        | —     | System clock and reset                                                                                                               |
| `HADDR`/`HBURST`/`HMASTLOCK`/`HPROT`/`HSIZE`/`HTRANS`/`HWDATA`/`HWRITE` | in        | —     | AHB-Lite manager-driven signals                                                                                                      |
| `HRDATA`/`HREADYOUT`/`HRESP`                                            | out       | —     | AHB-Lite subordinate response                                                                                                        |
| `HREADYIN`/`HSEL`                                                       | in        | —     | AHB-Lite decoder signals                                                                                                             |
| `spi_ss`                                                                | in        | 1     | Slave select, active low                                                                                                             |
| `spi_sck`                                                               | in        | 1     | Serial clock from the external host                                                                                                  |
| `spi_mosi`                                                              | in        | 1     | Host out, device in                                                                                                                  |
| `spi_miso`                                                              | out       | 1     | Device out, host in                                                                                                                  |
| `dbg_*`                                                                 | —         | —     | Debug port, present only under `DEBUG_PORT_EN`. Defined in [Debug Unit § Debug Port Interface](Debug%20Unit.md#debug-port-interface) |

External pin ownership follows the [GPIO Mux](GPIO%20Mux%20Specification.md)
pin-sharing scheme; the block's four pins occupy GPIO pads 0–3 in
alternate-function mode. Pads 0–2 (`spi_ss`, `spi_sck`, `spi_mosi`) default to
this alternate function unconditionally at reset — no strap, no firmware
action needed (`GRPR-SOC-027`). Pad 3 (`spi_miso`) also defaults to the
alternate function, but does not drive the pad until the Debug Unit's
`dbg_lock_active` asserts (`GRPR-SOC-028`, [GPIO Mux
`GRPR-GPIO-016`](GPIO%20Mux%20Specification.md)) — see `SPIS-SPEC-008` for why
that split exists.

## Register Map

| Offset | Name       | Access | Reset       | Purpose                                                    |
| ------ | ---------- | ------ | ----------- | ---------------------------------------------------------- |
| 0x00   | CTRL       | R/W    | 0x0000_0000 | Enable and reset SPI slave                                 |
| 0x04   | STATUS     | RO     | 0x0000_0054 | Current SPI and FIFO status                                |
| 0x08   | TXDATA     | WO     | -           | TX FIFO push (1–4 bytes by `HSIZE`)                        |
| 0x0C   | RXDATA     | RO     | -           | RX FIFO pop (1–4 bytes by `HSIZE`)                         |
| 0x10   | IRQ_STATUS | W1C    | 0x0000_0000 | Interrupt sources, write 1 to clear                        |
| 0x14   | IRQ_EN     | R/W    | 0x0000_0000 | Per-source interrupt enables                               |

Unlisted bits are reserved: read 0, write 0.

The map grew past four entries with `GRPR-SPIS-028`/`-029`, so the block decodes
`HADDR[4:2]` rather than the `HADDR[3:2]` that four registers needed. Offsets
above `IRQ_EN` are reserved and error, matching the `ADDR_SPI_M_MAX` handling in
the [SPI Master](SPI%20Master%20Specification.md).

This is the block's **own** register map. A second sub-aperture at offset `0x100`
carries the Debug Unit's registers — see § Debug Unit Register Window. The `STATUS` reset value
changes from `0x0000_0010` to `0x0000_0054` because it now reports FIFO state:
both FIFOs are empty out of reset, so `TX_EMPTY` and `RX_EMPTY` read 1.

## Debug Unit Register Window

The [Debug Unit](Debug%20Unit.md) has no AHB port of its own
(`GRPR-DBG-002`): it occupies no fabric slot and no address in the SoC memory
map, and its registers are reached over the debug port. That leaves firmware
with no way to touch them — which contradicts two SoC requirements that assume
it can:

- [`GRPR-SOC-023`](../Grouper%20SoC%20Specification.md#boot-flow) requires the
  boot ROM to **arm** the debug consent gates, including `CTRL.LOCK_EN` in the
  Debug Unit, before entering its UART load loop.
- `GRPR-SOC-026` requires strap-armed debug access to be **revocable by
  firmware**. That is a security property: without it, a chip strapped for debug
  could never be locked down again by software.

This block already owns the debug port, so it carries that access. A second
sub-aperture inside its existing 4 KiB region maps the Debug Unit's register
file into the CPU's address space, and each access there becomes one debug-port
register command. **No new fabric slot and no new bus master is added** — the
path already exists and is simply given an address.

### Map

The block's own registers keep offsets `0x00`–`0x14`. The Debug Unit's
`0x00`–`0x24` appear at `0x100`–`0x124`:

| SPI-S offset | Absolute | Debug offset | Register |
| --- | --- | --- | --- |
| `0x100` | `0x8000_7100` | `0x00` | `CTRL` |
| `0x104` | `0x8000_7104` | `0x04` | `STATUS` |
| `0x108` | `0x8000_7108` | `0x08` | `BUSADDR` |
| `0x10C` | `0x8000_710C` | `0x0C` | `BUSDATA` |
| `0x110` | `0x8000_7110` | `0x10` | `BUSERR` |
| `0x114` | `0x8000_7114` | `0x14` | `DBGPC` |
| `0x118` | `0x8000_7118` | `0x18` | `DBGTRACE` |
| `0x11C` | `0x8000_711C` | `0x1C` | `DBGTRACEH` |
| `0x120` | `0x8000_7120` | `0x20` | `DBGREG` |
| `0x124` | `0x8000_7124` | `0x24` | `DBGSEL` |

Access rules are the Debug Unit's, not this block's: `CTRL` and `DBGSEL` are
writable, `STATUS` is read-only with write-1-to-clear bits, and everything else
is read-only. This block does not re-implement them — it forwards the access and
returns what the Debug Unit says.

### Access semantics

| ID | Requirement |
| --- | --- |
| `GRPR-SPIS-036` | The block shall map the Debug Unit register file into its AHB aperture at offset `0x100`, one word per register, as § Map. The sub-aperture shall be selected by `HADDR[8]`. |
| `GRPR-SPIS-037` | Each access in the window shall be translated into exactly one `REG_READ` or `REG_WRITE` on the debug port, at the corresponding Debug Unit offset. No other mechanism shall reach these registers. |
| `GRPR-SPIS-038` | The block shall hold `HREADYOUT` low for the debug-port round trip, bounded by `GRPR-DBG-034`. A response carrying `dbg_rsp_err` shall be presented as a two-cycle AHB-Lite ERROR, consistent with the block's existing invalid-access handling. |
| `GRPR-SPIS-039` | Access to the window shall **not** be gated on any Debug Unit consent gate. |
| `GRPR-SPIS-040` | Where a wire-side request and a window access contend for the debug port, the wire side shall take precedence and the window access shall be stalled, not dropped or errored. |

`GRPR-SPIS-039` is the one that looks like it needs a caveat and does not.
Gating register access on `CTRL.LOCK_EN`/`CTRL.DBG_EN` would make a firmware
lockdown **irreversible**: firmware clears a gate to shut debug access down,
and by doing so would lose the only path back to the register that could
re-arm it. This is why `GRPR-DBG-040` states the same thing from the Debug
Unit's side. A consent gate must never be able to lock out the thing that
manages it.

`GRPR-SPIS-040`'s precedence is not arbitrary. An external host mid-frame is
paced by `SCK`, which this block does not drive and cannot stretch; a stalled
wire-side request would drop a byte. An AHB access has `HREADYOUT` and can be
made to wait for as long as necessary. The side that *can* wait is the side that
does.

### What this does not give firmware

Only the register file. `LOCK`, `UNLOCK`, `STEP`, `RESUME`, `STATE_READ`, and
debug bus reads and writes are **not** exposed through the window, and shall not
be added to it.

Firmware already has the bus, so debug-sourced memory access would add nothing;
and halting or stepping the CPU from firmware running *on* that CPU is not a
coherent operation. What firmware lacks and genuinely needs is the consent gates
(`GRPR-SOC-023`, `-026`) and the post-mortem status a session leaves behind
(`GRPR-DBG-037`). The window supplies exactly those and stops.

Naming the limit here is deliberate. Removing the Debug Unit's subordinate port
was meant to prevent a second CPU-facing control surface; a window that grew to
carry commands would reintroduce it under a different name.

## CTRL — 0x00

| Bits | Field         | Access | Description                                                                                                                                     |
| ---- | ------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | ENABLE        | R/W    | Enable SPI slave peripheral                                                                                                                     |
| 1    | SOFT_RESET    | WO     | Software reset the SPI slave state machine to its default state                                                                                 |
| 2    | CPHA          | R/W    | Clock phase.                                                                       |
| 3    | CPOL          | R/W    | Clock polarity.                                                                              |
| 31:4 | Reserved      | -      | Read 0, write 0                                                                                                                                 |

Writing 1 to SOFT_RESET resets the SPI slave state machine, aborts any
outstanding debug request (`GRPR-SPIS-019`), and **flushes both FIFOs**, so a
recovering driver does not inherit bytes from the transaction it just abandoned.
`STATUS` returns to its reset value and any pending multi-lane access is
discarded. It does not clear `IRQ_STATUS`: the flags record what already
happened, and firmware clears them with a W1C write when it has read them.

The bit is specified to self-clear after the reset completes; **the current RTL
does not self-clear it** — see `SPIS-SPEC-006`.

Bit 4 (`DEBUG_PORT_EN`) is withdrawn: an earlier revision used it to gate
retargeting of `SPI_READ`/`SPI_WRITE`/`FAST_READ`/`FAST_WRITE` onto the debug
port. That retargeting is itself withdrawn (`GRPR-SPIS-030`) — the dedicated
debug opcodes of § Debug Command Encoding decode unconditionally, gated only
by the `DEBUG_PORT_EN` build *parameter*, not any register bit — so there was
nothing left for this bit to control. It is now reserved like the rest of
`31:4`. The Debug Unit's own consent gates (`CTRL.LOCK_EN`, `CTRL.DBG_EN`,
`GRPR-DBG-007`, `GRPR-DBG-022`) still decide whether a forwarded command does
anything, and those reset to 0 unconditionally (`GRPR-SOC-029`) — `DBG_ENABLE`
is what sets them together in one wire command.

## STATUS — 0x04

| Bits | Field      | Access | Description                                                                                 |
| ---- | ---------- | ------ | ------------------------------------------------------------------------------------------- |
| 0    | BUSY       | RO     | SPI transaction in progress                                                                 |
| 1    | RX_VALID   | RO     | At least one received byte is available. Equivalent to `!RX_EMPTY`, kept for compatibility  |
| 2    | TX_READY   | RO     | The TX FIFO can accept at least one byte. Equivalent to `!TX_FULL`, kept for compatibility  |
| 3    | DEBUG_BUSY | RO     | A debug request is outstanding on the debug port. Reads 0 when `DEBUG_PORT_EN` is not built |
| 4    | RX_EMPTY   | RO     | RX FIFO is empty                                                                            |
| 5    | RX_FULL    | RO     | RX FIFO is full — the next received byte will set `IRQ_STATUS.OVERRUN`                      |
| 6    | TX_EMPTY   | RO     | TX FIFO is empty — the next byte the host clocks will set `IRQ_STATUS.UNDERRUN`             |
| 7    | TX_FULL    | RO     | TX FIFO is full — a further `TXDATA` write will set `IRQ_STATUS.OVERFLOW`                   |
| 11:8 | RX_LEVEL   | RO     | Number of bytes currently held in the RX FIFO, 0 to `FIFO_DEPTH`                             |
| 31:12| Reserved   | -      | Read 0                                                                                      |

Reset value 0x0000_0054 reflects `RX_EMPTY` = `TX_EMPTY` = 1 with everything
else 0. Note `TX_READY` is 1 at reset as before, but it now reads as `!TX_FULL`
rather than as a single-byte handshake.

`RX_LEVEL` is what makes a short packed read unambiguous. `GRPR-SPIS-025` lets a
word read return fewer than four bytes, zero-filling the rest; without a count,
firmware could not distinguish a zero byte that was received from a lane that was
never filled. Read `RX_LEVEL` before a packed read, or read `IRQ_STATUS.UNDERFLOW`
after it.

`BUSY` is specified against the transfer state machine: it is 1 from the first
sampled `SCK` edge of a transaction until `SS` is released. It is currently
hardwired to 0 in RTL — see `SPIS-SPEC-004`.

## TXDATA — 0x08

| Access | Behaviour                                                                      |
| ------ | ------------------------------------------------------------------------------ |
| Write  | Pushes 1–4 bytes into the TX FIFO, one per asserted `HSIZE` byte lane          |
| Read   | Returns 0. `TXDATA` is write-only and a read is not an error                   |

| Bits  | Field | Access | Description                                                       |
| ----- | ----- | ------ | ----------------------------------------------------------------- |
| 7:0   | DATA0 | WO     | First byte transmitted, queued when `HSIZE` selects lane 0        |
| 15:8  | DATA1 | WO     | Second byte, queued when lane 1 is selected                       |
| 23:16 | DATA2 | WO     | Third byte, queued when lane 2 is selected                        |
| 31:24 | DATA3 | WO     | Fourth byte, queued when lane 3 is selected                       |

Writing a full TX FIFO drops the surplus lanes and sets `IRQ_STATUS.OVERFLOW`
(`GRPR-SPIS-026`).

## RXDATA — 0x0C

| Access | Behaviour                                                              |
| ------ | ---------------------------------------------------------------------- |
| Read   | Pops 1–4 bytes from the RX FIFO, one per asserted `HSIZE` byte lane    |
| Write  | Error — `RXDATA` is read-only                                          |

| Bits  | Field | Access | Description                                                    |
| ----- | ----- | ------ | -------------------------------------------------------------- |
| 7:0   | DATA0 | RO     | Oldest byte in the RX FIFO                                     |
| 15:8  | DATA1 | RO     | Next byte, when `HSIZE` selects lane 1                         |
| 23:16 | DATA2 | RO     | Next byte, when lane 2 is selected                             |
| 31:24 | DATA3 | RO     | Next byte, when lane 3 is selected                             |

Reading more bytes than the FIFO holds returns what is available, zeroes the
remaining lanes and sets `IRQ_STATUS.UNDERFLOW` (`GRPR-SPIS-025`). `STATUS.RX_LEVEL`
gives the count, so a short read is distinguishable from received zero bytes.

## Buffered Data Path

### Why the FIFOs exist

`GRPR-SPIS-013` requires the block to accept one payload byte every 2 µs, which
at the 16 MHz system clock of `GRPR-SOC-011` is 32 `HCLK` cycles. Without
buffering every byte needs its own AHB round trip inside that window, and a
missed deadline overwrites the previous byte with no indication that anything
was lost. A four-deep FIFO relaxes the service interval to 8 µs and makes an
overrun reportable (`IRQ_STATUS.OVERRUN`), which is what `GRPR-SPIS-012`'s
firmware-load throughput depends on.

### Multi-byte access and bus stall (`GRPR-SPIS-027`)

`TXDATA` and `RXDATA` move one byte per asserted `HSIZE` byte lane, **low lane
first**: a 32-bit write of `0xDDCCBBAA` transmits `AA`, `BB`, `CC`, `DD`, and a
32-bit read returns the four oldest received bytes with the oldest in bits 7:0.
That lets firmware assemble or consume a four-byte payload with a single load or
store instead of four.

The FIFO accepts one access per cycle, so the lanes are serialised and the block
holds `HREADYOUT` low until the last lane is accepted, making the whole
multi-lane access a single AHB transfer:

| Access size | Lanes | Wait states |
| ----------- | ----- | ----------- |
| byte        | 1     | 0           |
| half        | 2     | 1           |
| word        | 4     | 3           |

A single-lane access is accepted in the cycle it lands, so byte-at-a-time
firmware costs no wait states.

Two properties bound the stall deliberately:

- **It is bounded by lane count, not by the wire.** At most 3 wait states for a
  32-bit access, independent of `SCK` or the state of the transfer.
- **It is never wire-paced.** A write that finds the TX FIFO full, or a read that
  finds too few bytes in the RX FIFO, completes immediately rather than waiting
  for the external host; the shortfall is reported through `OVERFLOW`/`UNDERFLOW`.
  This matters more here than in the [SPI Master](SPI%20Master%20Specification.md):
  the far end is an external host the SoC does not control at all, so a
  wire-paced stall could be held indefinitely. `cpu_ss` is single-master, so a
  held `HREADY` blocks instruction fetch and the CPU could never run the loop
  that services the FIFO.

Back-pressure for a transfer longer than `FIFO_DEPTH` is expressed through
`STATUS` and `IRQ_STATUS` polling, not by holding the bus.

## IRQ_STATUS — 0x10 (write-1-to-clear)

| Bits | Field    | Description                                                            |
| ---- | -------- | ---------------------------------------------------------------------- |
| 0    | RX_VALID | A byte was received into the RX FIFO                                   |
| 1    | UNDERRUN | The host clocked out a byte with the TX FIFO empty during a transfer   |
| 2    | OVERRUN  | A byte arrived with the RX FIFO full during a transfer                 |
| 3    | Reserved | Read 0, write 0                                                        |
| 4    | UNDERFLOW| AHB read of `RXDATA` requesting more bytes than the RX FIFO holds      |
| 5    | OVERFLOW | AHB write to `TXDATA` with the TX FIFO full                            |

The wire events and the AHB access errors are on separate bits, following the
same split the [SPI Master](SPI%20Master%20Specification.md) draws for
`SPIM-SPEC-001`: `UNDERRUN`/`OVERRUN` are the in-transfer FIFO events, caused by
the external host outrunning firmware, and `UNDERFLOW`/`OVERFLOW` are the
bus-side access errors, caused by firmware mis-sizing its own access. Confusing
the two would send a debugger looking at the wrong side of the block. All four
are independently enabled and cleared.

Bit positions match the SPI Master's where the meaning matches, so a shared
driver header can use one set of masks. Bit 3 is reserved rather than reused: the
Master's `CFG_ERR` has no Slave analogue yet, and leaving the position vacant
keeps the two maps aligned.

Writing 1 to a bit clears it; writing 0 leaves it unchanged. A source setting in
the same cycle as a clear wins, so an event is never lost to a concurrent W1C.

## IRQ_EN — 0x14

Per-source enables, at the same bit positions as `IRQ_STATUS`. A source
contributes to `irq` only when its `IRQ_EN` bit is set; `IRQ_STATUS` still
records the event regardless, so a polling driver needs no enables at all.

| Bits | Field     | Access | Description                                |
| ---- | --------- | ------ | ------------------------------------------ |
| 0    | RX_VALID  | R/W    | Enable the byte-received interrupt         |
| 1    | UNDERRUN  | R/W    | Enable the transmit-underrun interrupt     |
| 2    | OVERRUN   | R/W    | Enable the receive-overrun interrupt       |
| 3    | Reserved  | -      | Read 0, write 0                            |
| 4    | UNDERFLOW | R/W    | Enable the RX-FIFO-short-read interrupt    |
| 5    | OVERFLOW  | R/W    | Enable the TX-FIFO-full write interrupt    |

Unlike the SPI Master, there is no `CTRL.IE_COMPLETE`/`CTRL.IE_ERR` master enable
above these bits — the Master's two-level gating exists to separate completion
from error reporting on a block that raises both, and this block has no
transaction-complete event of its own. `IRQ_EN` is the only gate.

**The `irq` output has no CPU interrupt line today.** `cpu_ss`'s vector is
`{uart_rx_error_irq, uart_rx_irq}` and is full, so this output joins QSPI's and
the SPI Master's as an unconnected port at `periph_ss`. Firmware polls
`IRQ_STATUS`. See `SPIS-SPEC-011`.

## Clocking Strategy

`GRPR-SPIS-009`: Single system clock (`HCLK`) for everything, per the source.

## Reset Strategy

`GRPR-SPIS-010`: Active-low reset, asyncronous set with synchronous reset. Reset clears and restarts the design and stops any ongoing SPI transfer.

## CDC Strategy

| ID              | Requirement                                                                                                                                                                                    |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GRPR-SPIS-021` | The external SPI inputs shall be synchronised to `HCLK` before use. Synchronisation is performed by the two-stage synchronisers at the SoC top level, one per GPIO pad, not inside this block. |

`SCK` is **not** treated as a clock domain: it is sampled into `HCLK` and
edge-detected, so the whole SPI datapath runs synchronously to `HCLK`. That is
what bounds the maximum usable `SCK` rate — see § Performance Targets.

The top-level synchronisers are individually bypassable from firmware through
the GPIO `SYNC_EN_N` register. Bypassing them for an SPI slave pad forfeits the
metastability guarantee and is not supported for this block.

*(This requirement previously carried the ID `GRPR-SPIS-004`, duplicating the
Key Functionality requirement of the same number, and credited the GPIO Mux
with synchronisation it does not perform. Both are corrected here —
`SPIS-SPEC-003`.)*

## Performance Targets

| ID              | Requirement                                                |
| --------------- | ---------------------------------------------------------- |
| `GRPR-SPIS-011` | SPI clock speeds up to 4 MHz.                              |
| `GRPR-SPIS-012` | Firmware-load throughput up to 0.5 MB/s.                   |
| `GRPR-SPIS-013` | Receives one payload byte every 2 µs at maximum SPI clock. |

**These three figures were corrected downward from 10 MHz / 1.25 MB/s /
0.8 µs.** `SCK` is oversampled in the `HCLK` domain rather than being a clock
in its own right (see § CDC Strategy), so reliable edge detection needs
`SCK` no faster than roughly `HCLK`/4. At the 16 MHz system clock of
[`GRPR-SOC-011`](../Grouper%20SoC%20Specification.md#clocking--reset-architecture)
that is 4 MHz, and the two derived throughput figures scale with it. The
original numbers were not achievable by this implementation. Reaching 10 MHz
would require running the SPI datapath in a genuine `SCK` domain with a proper
clock-domain crossing — see `SPIS-SPEC-002`.

## Size Estimate

TBD (per source).

## Open Items

- `SPIS-SPEC-001` — **Resolved.** The relationship between this block's
  firmware-load path and the UART boot sequence is now defined: there is no
  separate firmware-load datapath here. A host loads firmware by issuing debug
  commands, which the [Debug Unit](Debug%20Unit.md) turns into RAM writes; the
  two boot paths are peers, per
  [`GRPR-SOC-022`](../Grouper%20SoC%20Specification.md#boot-flow).
- `SPIS-SPEC-002` — **Partly resolved.** The `SCK` vs `HCLK` question is
  answered: `SCK` is oversampled in the `HCLK` domain, and § Performance
  Targets has been corrected to the rate that actually supports. What remains
  open is whether a genuine `SCK` clock domain is wanted later to reach the
  original 10 MHz target; that would be a substantial redesign of the datapath.
- `SPIS-SPEC-003` — **Resolved.** The duplicated `GRPR-SPIS-004` in § CDC
  Strategy is renumbered `GRPR-SPIS-021`, and its incorrect attribution of
  synchronisation to the GPIO Mux is corrected.
- `SPIS-SPEC-004` — **Respecified, not yet implemented.** `STATUS.BUSY` now has
  a definition to build to: 1 from the first sampled `SCK` edge of a transaction
  until `SS` is released (§ STATUS). It is still hardwired to 0 in RTL.
- `SPIS-SPEC-005` — `CTRL.CPHA` and `CTRL.CPOL` are specified and required by
  `GRPR-SPIS-002`, but are not implemented in the current RTL.
- `SPIS-SPEC-006` — **Respecified, not yet implemented.** `CTRL.SOFT_RESET` is
  specified to self-clear and now also to flush both FIFOs (§ CTRL). The current
  RTL neither clears it nor has FIFOs to flush.
- `SPIS-SPEC-007` — **Resolved by removing the shared path.** `FAST_READ` no
  longer touches the debug port at all (`GRPR-SPIS-030`, withdrawn), so its
  own lack of dummy cycles is a pure FIFO-read timing question, unrelated to
  the Debug Unit's response latency. `BUS_READ` and `DBG_READ` — the opcodes
  that do reach the debug port — specify one dummy byte unconditionally
  (`GRPR-SPIS-046`), which is what covers the round trip now.
- `SPIS-SPEC-008` — **Resolved by an unconditional reset default, superseding
  an earlier resolution by strap.** An earlier revision reached pads 0–3 with
  no firmware involvement by sampling GPIO pad 15 as a debug strap at reset.
  That mechanism is withdrawn (see [Debug Unit `DBG-SPEC-001`](Debug%20Unit.md#open-items)
  for why). In its place, pads 0–2 default to the SPI-slave alternate function
  unconditionally — no pin sampled, no strap needed (`GRPR-SOC-027`). Pad 3
  defaults to the alternate function too, but is held from driving until a
  lock is accepted (`GRPR-SOC-028`, `GRPR-GPIO-016`), so an external host can
  always reach this block's inputs; what it cannot do before completing a
  `DBG_ENABLE`/`BUS_LOCK` exchange is see a response.
- `SPIS-SPEC-009` — The AHB error response is one cycle in the current RTL
  (`ahb_spi_s.sv`, with an existing `FIXME`), which is an AHB-Lite protocol
  violation; errors must be two cycles. **This is now load-bearing rather than
  cosmetic.** With `GRPR-SPIS-027` the block drives `HREADYOUT` low for the first
  time, so the error response and the lane stall share that signal and their
  precedence has to be defined: the error wins, and its second cycle presents
  `HREADYOUT` high on schedule regardless of the stall. The SPI Master resolves
  the same collision the same way.
- `SPIS-SPEC-010` — **Resolved, differently than either earlier pass.** The
  legacy data commands' 24-bit address never reaches the debug port at all —
  that retargeting is withdrawn (`GRPR-SPIS-030`). The separate 32-bit debug
  address phase an earlier draft specified, which a later pass called
  withdrawn in favour of the legacy commands, is the one that has actually
  shipped, as `BUS_WRITE`/`BUS_READ` (§ Debug Command Encoding). There is now
  exactly one debug address width, not two competing ones.
- `SPIS-SPEC-011` — **The register map aliases across its 4 KiB window, and the
  debug window now constrains that.** Only the low address bits are decoded, so
  the block's registers repeat every 32 bytes with the `HADDR[4:2]` this
  specification requires — 128 replicas across the aperture. Harmless while the
  block owned the whole window; **not harmless now**, because `GRPR-SPIS-036`
  claims offset `0x100`, and under the current decode `0x100` is itself an alias
  of `0x00`. Implementing the window therefore requires decoding `HADDR[8]` as a
  sub-aperture select, which the RTL does not do. Until it does, a firmware write
  intended for Debug `CTRL` lands on the SPI Slave's own `CTRL`. The full decode
  should be `HADDR[8]` selecting the sub-aperture and `HADDR[4:2]` the register
  within it, with everything else reserved. The SPI Master carries the aliasing
  half of this issue as `SPIM-ISSUE-020`, but not the collision, having no second
  window. This ID was already referenced by `V-SPIS-DIR-005` in the verification
  plan before it was defined here.
- `SPIS-SPEC-012` — **`GRPR-SPIS-029`'s `irq` output has no CPU interrupt line.**
  `cpu_ss` is built with `NUM_IRQ = 2`, both taken by the UART, so the SPI Slave
  joins QSPI and the SPI Master in having its `irq` left unconnected at
  `periph_ss`. Firmware must poll `IRQ_STATUS`. Widening the vector is a
  SoC-level change affecting `cpu_ss`, `digital_ss` and `periph_ss`, and is out of
  scope for this block.
- `SPIS-SPEC-013` — **The FIFO primitive corrupts on a write-when-full.**
  `small_sync_fifo` holds its write pointer when full but still executes
  `memory[wptr] <= wdata`, so an unqualified push overwrites the oldest entry.
  Any implementation of `GRPR-SPIS-024` must gate the push on `!full` itself
  rather than relying on the FIFO. The same hazard is recorded as `L3` in the
  [UART Specification](UART%20Specification.md).
- Size estimate not yet available. The `periph_ss` stub reserves 635 GE for this
  block against the 317 GE it synthesises to today, explicitly to cover "the
  two-cycle error response, IRQs, and the FIFOs" — i.e. this specification's
  additions are inside the area already budgeted.

- `SPIS-SPEC-014` — **Resolved.** § Debug Command Encoding gives `BUS_LOCK`,
  `BUS_UNLOCK`, `BUS_STATUS`, `DBG_READ` (`STATE_READ`), `DBG_STEP`, and
  `DBG_RESUME` each a dedicated wire opcode, and `BUS_WRITE`/`BUS_READ` a
  32-bit address phase that reaches the peripheral aperture. Register access
  remains window-only by design (§ "What this does not give firmware"), not
  because the wire side lacks room for it.
- `SPIS-SPEC-015` — **The debug datapath is inert, in three separate ways.**
  No SPI-sourced or window access reaches real memory or a real register in
  silicon or in SoC-level simulation. The translation is verified only against a
  testbench stub (`hw/tb/spi_s/spi_s_utils.py`), on the standalone `debug_port`
  target. Each of the three needs fixing independently:
    1. **No Debug Unit exists.** `hw/rtl/dbg_ctrl.sv` is a ~60-line skeleton that
       does not compile — a trailing comma in its parameter list, a dangling
       `input logic` with no identifier, and `HRDATA` declared as an output. It
       is instantiated nowhere and named by no `.core` file. It also declares an
       AHB Master Interface, which `GRPR-DBG-001` now forbids.
    2. **`periph_ss` does not connect the ports.** The `ahb_spi_s` instantiation
       omits `irq` and all ten `dbg_*` signals from its port list — not tied off,
       absent. Verilator reports `PINMISSING`; the SoC still elaborates, but
       `dbg_req_ready` and `dbg_rsp_valid` float.
    3. **`DEBUG_PORT_EN` is not overridden there**, so it takes its default of 0
       and the whole transport constant-folds away in every SoC build.
- `SPIS-SPEC-016` — **The window is specified but unimplemented, and needs more
  than a decode.** `dbg_req_addr` and `dbg_req_wdata` are hardwired to wire-side
  sources, so an AHB-initiated request needs muxes on both, a request trigger,
  the `HADDR[8]` sub-aperture decode of `SPIS-SPEC-011`, the round-trip stall of
  `GRPR-SPIS-038`, and the contention arbiter of `GRPR-SPIS-040`. None of this
  exists yet.
- `SPIS-SPEC-017` — **A debug bus error shares an interrupt bit with a wire-side
  event.** `dbg_err_evt` is folded into `IRQ_STATUS.OVERRUN`, which is otherwise
  the RX-FIFO-overrun flag. That defeats the wire-side/bus-side separation this
  block's own design states, and it is a third category besides: a debug bus
  error is neither the host outrunning firmware nor firmware mis-sizing an
  access. It needs its own bit.
## Verification Cross-Reference

| Req ID          | Verification Item(s)                                                                 |
| --------------- | ------------------------------------------------------------------------------------ |
| `GRPR-SPIS-001` | `V-SPIS-STM-001`, `V-SPIS-CHK-001`                                                   |
| `GRPR-SPIS-002` | `V-SPIS-STM-002`, `V-SPIS-COV-001`                                                   |
| `GRPR-SPIS-003` | `V-SPIS-STM-003`, `V-SPIS-CHK-002`                                                   |
| `GRPR-SPIS-004` | `V-SPIS-STM-004`, `V-SPIS-CHK-003`                                                   |
| `GRPR-SPIS-005` | `V-SPIS-STM-005`, `V-SPIS-COV-002`                                                   |
| `GRPR-SPIS-006` | `V-SPIS-CHK-004`                                                                     |
| `GRPR-SPIS-007` | `V-SPIS-STM-006`                                                                     |
| `GRPR-SPIS-008` | `V-SPIS-STM-007`, `V-SPIS-CHK-005`                                                   |
| `GRPR-SPIS-009` | `V-SPIS-CHK-006` (blocked on the open clocking question)                             |
| `GRPR-SPIS-010` | `V-SPIS-STM-008`, `V-SPIS-CHK-007`                                                   |
| `GRPR-SPIS-011` | `V-SPIS-CHK-008`                                                                     |
| `GRPR-SPIS-012` | `V-SPIS-CHK-009`                                                                     |
| `GRPR-SPIS-013` | `V-SPIS-CHK-010`                                                                     |
| `GRPR-SPIS-014` | `V-SPIS-STM-009`, `V-SPIS-CHK-011`                                                   |
| `GRPR-SPIS-015` | `V-SPIS-STM-010`, `V-SPIS-COV-003`                                                   |
| `GRPR-SPIS-016` | `V-SPIS-STM-011`, `V-SPIS-CHK-012`                                                   |
| `GRPR-SPIS-017` | `V-SPIS-CHK-013`                                                                     |
| `GRPR-SPIS-018` | `V-SPIS-STM-012`, `V-SPIS-CHK-014`                                                   |
| `GRPR-SPIS-019` | `V-SPIS-CHK-015`                                                                     |
| `GRPR-SPIS-020` | `V-SPIS-CHK-016` (elaboration check: `DEBUG_PORT_EN` = 0 leaves the block unchanged) |
| `GRPR-SPIS-021` | `V-SPIS-CHK-006`                                                                     |
| `GRPR-SPIS-022` | `V-SPIS-STM-013`, `V-SPIS-CHK-017`                                                   |
| `GRPR-SPIS-023` | `V-SPIS-DIR-031`, `V-SPIS-CHK-018`                                                   |
| `GRPR-SPIS-024` | `V-SPIS-DIR-032`, `V-SPIS-CHK-019`                                                   |
| `GRPR-SPIS-025` | `V-SPIS-DIR-033`, `V-SPIS-DIR-034`, `V-SPIS-CHK-020`                                 |
| `GRPR-SPIS-026` | `V-SPIS-DIR-035`, `V-SPIS-CHK-021`                                                   |
| `GRPR-SPIS-027` | `V-SPIS-DIR-036`, `V-SPIS-DIR-037`, `V-SPIS-STM-014`, `V-SPIS-CHK-022`               |
| `GRPR-SPIS-028` | `V-SPIS-DIR-038`, `V-SPIS-DIR-039`, `V-SPIS-CHK-023`                                 |
| `GRPR-SPIS-029` | `V-SPIS-DIR-040`, `V-SPIS-CHK-024`                                                   |
| `GRPR-SPIS-030` | `V-SPIS-DIR-045`, `V-SPIS-DIR-052`                                                   |
| `GRPR-SPIS-031` | `V-SPIS-DIR-046`                                                                     |
| `GRPR-SPIS-032` | `V-SPIS-DIR-049`                                                                     |
| `GRPR-SPIS-033` | `V-SPIS-DIR-050`                                                                     |
| `GRPR-SPIS-034` | `V-SPIS-DIR-048`                                                                     |
| `GRPR-SPIS-035` | `V-SPIS-DIR-051`                                                                     |
| `GRPR-SPIS-036` | `V-SPIS-DIR-053`, `V-SPIS-DIR-054`                                                   |
| `GRPR-SPIS-037` | `V-SPIS-DIR-053`, `V-SPIS-CHK-025`                                                   |
| `GRPR-SPIS-038` | `V-SPIS-DIR-055`, `V-SPIS-DIR-056`                                                   |
| `GRPR-SPIS-039` | `V-SPIS-DIR-057`                                                                     |
| `GRPR-SPIS-040` | `V-SPIS-DIR-058`                                                                     |
| `GRPR-SPIS-041` | `V-SPIS-DIR-059` (`DBG_ENABLE` decoded regardless of `CTRL.ENABLE`) |
| `GRPR-SPIS-042` | `V-SPIS-DIR-060` (Debug Unit `CTRL.LOCK_EN`/`DBG_EN` set end-to-end) |
| `GRPR-SPIS-043` | `V-SPIS-CHK-026` (no distinguishable `MISO` response to `DBG_ENABLE`), `V-SPIS-DIR-061` (`BUS_LOCK` response confirms success) |
| `GRPR-SPIS-044` | `V-SPIS-DIR-062` (each dedicated opcode decoded unconditionally, one debug-port command per opcode) |
| `GRPR-SPIS-045` | `V-SPIS-DIR-063` (`BUS_WRITE`/`BUS_READ` 32-bit address reaches the AHB peripheral aperture) |
| `GRPR-SPIS-046` | `V-SPIS-DIR-064` (one dummy byte before the first response byte on `BUS_READ`/`DBG_READ`) |
| `GRPR-SPIS-047` | `V-SPIS-DIR-065` (`BUS_LOCK`'s flags byte maps to `LOCK`'s `wdata[0]`/`wdata[8]`) |
| `GRPR-SPIS-048` | `V-SPIS-DIR-066` (opcode `0x56` produces no request and no response) |

See [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md) for the full item definitions and test list.
