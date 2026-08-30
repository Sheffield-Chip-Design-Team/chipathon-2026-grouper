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
`DEBUG_PORT_EN` parameter it decodes an additional set of debug commands and
forwards each as one request on the debug port of the
[Debug Unit](Debug%20Unit.md), which is the block that actually masters the bus
and controls the CPU. This block frames and forwards; it does not master any
bus, hold CPU state, or decide whether a debug command is permitted.

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
| `GRPR-SPIS-006` | The block shall occupy a 4 KiB region of the AHB peripheral aperture.                                                 |

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
| `GRPR-SPIS-015`      | The block shall decode the debug opcodes of § Debug Command Encoding and translate each into exactly one request on the debug port. It shall not itself interpret addresses, master any bus, or hold CPU state.                                                                                                                                                                                                               |
| `GRPR-SPIS-016`      | Debug opcodes shall be forwarded only while `CTRL.DEBUG_PORT_EN` is 1. Received otherwise they shall be ignored and shall not disturb the debug port. Whether a forwarded command is then honoured is the Debug Unit's decision, not this block's — see `GRPR-DBG-007` and `GRPR-DBG-022`.                                                                                                                                    |
| `GRPR-SPIS-017`      | The block shall present at most one debug request at a time, and shall hold SPI-side pacing — stalling the response bytes of a read — until the response arrives or the transaction is aborted.                                                                                                                                                                                                                               |
| `GRPR-SPIS-018`      | Deassertion of `SS` mid-command shall abort that command at the transport level without leaving the debug port mid-handshake. It shall **not** by itself release a lock or resume the CPU; those persist until an explicit command, per `GRPR-DBG-014`.                                                                                                                                                                       |
| `GRPR-SPIS-019`      | `CTRL.SOFT_RESET` shall reset the SPI command FSM and abort any outstanding debug request, without altering any Debug Unit state. Note this is an AHB register write and so is unavailable while the CPU is halted; `GRPR-SPIS-022` provides the equivalent recovery from the SPI side.                                                                                                                                       |
| `GRPR-SPIS-022`      | Deassertion of `SS` shall return the command decoder to its idle state unconditionally, so that an external host can always resynchronise by raising `SS` and starting a new transaction. This shall hold regardless of how far through a command the block had progressed, and shall not depend on any AHB access.                                                                                                           |
| `GRPR-SPIS-INFO-001` | The debug port is transport-neutral. The opcode encoding below is this block's wire framing only; a JTAG or UART transport would use its own encoding over the same port.                                                                                                                                                                                                                                                     |

## Debug Command Encoding

Present only when `DEBUG_PORT_EN` is set. Each opcode maps to one debug-port
command; the address and data phases supply `dbg_req_addr` and `dbg_req_wdata`.

| Opcode | Name          | Phases after opcode                          | Debug-port command |
| ------ | ------------- | :------------------------------------------- | ------------------ |
| `0x67` | `DBG_ENABLE`  | none                                         | `ENABLE`           |
| `0x6B` | `DBG_DISABLE` | none                                         | `DISABLE`          |
| `0x5A` | `BUS_LOCK`    | 1 flags byte                                 | `LOCK`             |
| `0xA5` | `BUS_UNLOCK`  | none                                         | `UNLOCK`           |
| `0x51` | `BUS_WRITE`   | 32-bit address + N data bytes                | `WRITE`            |
| `0x52` | `BUS_READ`    | 32-bit address + 1 dummy byte + N data bytes | `READ`             |
| `0x53` | `BUS_STATUS`  | 1 dummy byte + 4 status bytes                | `STATUS`           |
| `0x54` | `DBG_READ`    | 1 selector byte + 1 dummy + 4 data bytes     | `STATE_READ`       |
| `0x55` | `DBG_STEP`    | 1 count byte                                 | `STEP`             |
| `0x57` | `DBG_RESUME`  | none                                         | `RESUME`           |

The address phase for `BUS_WRITE`/`BUS_READ` is **32 bits**, not the
24 bits the legacy commands use. A 24-bit address cannot reach the AHB
peripheral aperture, and a 32-bit phase lets a host use the CPU's own memory
map unchanged — see `GRPR-DBG-010`. The legacy `SPI_READ`/`FAST_READ`/
`SPI_WRITE`/`FAST_WRITE` commands keep their 24-bit phase, so APS6404L
compatibility (`GRPR-SPIS-003`) is unaffected.

Opcode `0x56` is reserved and shall be refused. It carried an
arbitrary-execution-redirect command in an earlier draft, removed per
[Debug Unit `DBG-SPEC-002`](Debug%20Unit.md#open-items); the encoding is left
vacant rather than reused so a stale host gets a clean refusal.

None of these opcodes alias a real APS6404L command. `BUS_LOCK` and
`BUS_UNLOCK` are bitwise complements, giving them a Hamming distance of 8, so
no bit error on `MOSI` can turn a release into a bus seizure.

`0x55` is a classic bus-test pattern, which would normally be a poor choice.
It is acceptable here because `DBG_STEP` is decodable only while the CPU is
already halted (`GRPR-DBG-022`), so a spurious `0x55` can at worst advance a
stopped CPU by a few instructions. This exception is deliberate.

The dummy byte on `BUS_READ` and `DBG_READ` covers the debug-port round trip.
See `SPIS-SPEC-007` for the open question of whether one byte suffices at the
maximum SCK rate.

**Releasing a lock, and recovering from a wedged command.** A lock taken with
`BUS_LOCK` is released with `BUS_UNLOCK` over the same SPI link — that is the
normal path, and it works whether or not the CPU is halted, since the CPU plays
no part in it (`GRPR-DBG-013`). If a command is interrupted or the host loses
track of where it is in a phase, raising `SS` returns this block's decoder to
idle (`GRPR-SPIS-022`) without disturbing the lock, so the host can simply
start a fresh transaction and issue `BUS_UNLOCK`. `CTRL.SOFT_RESET` does the
same thing but is an AHB write, so it is *not* available while the CPU is
halted — `SS` deassertion is the SPI-side equivalent and the one a host should
rely on. Should the host disappear entirely, the Debug Unit's watchdog
(`GRPR-DBG-016`) releases the lock on its own.

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
| `GRPR-SPIS-020` | The `DEBUG_PORT_EN` *parameter* shall select whether the debug port of `GRPR-SPIS-014` is instantiated, and shall default to disabled. This is the build-time parameter, distinct from the `CTRL.DEBUG_PORT_EN` register bit, which gates forwarding at run time in a build where the port exists. |

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
alternate-function mode. They default to GPIO out of reset unless the debug
strap on pad 15 is sampled high, which assigns them in hardware — see
`GRPR-SOC-024` and `SPIS-SPEC-008`.

## Register Map

| Offset | Name       | Access | Reset       | Purpose                                                    |
| ------ | ---------- | ------ | ----------- | ---------------------------------------------------------- |
| 0x00   | CTRL       | R/W    | 0x0000_0010 | Enable and reset SPI slave, and gate debug forwarding      |
| 0x04   | STATUS     | RO     | 0x0000_0054 | Current SPI and FIFO status                                |
| 0x08   | TXDATA     | WO     | -           | TX FIFO push (1–4 bytes by `HSIZE`)                        |
| 0x0C   | RXDATA     | RO     | -           | RX FIFO pop (1–4 bytes by `HSIZE`)                         |
| 0x10   | IRQ_STATUS | W1C    | 0x0000_0000 | Interrupt sources, write 1 to clear                        |
| 0x14   | IRQ_EN     | R/W    | 0x0000_0000 | Per-source interrupt enables                               |

Unlisted bits are reserved: read 0, write 0.

The map grew past four entries with `GRPR-SPIS-028`/`-029`, so the block decodes
`HADDR[4:2]` rather than the `HADDR[3:2]` that four registers needed. Offsets
above `IRQ_EN` are reserved and error, matching the `ADDR_SPI_M_MAX` handling in
the [SPI Master](SPI%20Master%20Specification.md). The `STATUS` reset value
changes from `0x0000_0010` to `0x0000_0054` because it now reports FIFO state:
both FIFOs are empty out of reset, so `TX_EMPTY` and `RX_EMPTY` read 1.

## CTRL — 0x00

| Bits | Field         | Access | Description                                                                                                                                     |
| ---- | ------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | ENABLE        | R/W    | Enable SPI slave peripheral                                                                                                                     |
| 1    | SOFT_RESET    | WO     | Software reset the SPI slave state machine to its default state                                                                                 |
| 2    | CPHA          | R/W    | Clock phase.                                                                       |
| 3    | CPOL          | R/W    | Clock polarity.                                                                              |
| 4    | DEBUG_PORT_EN | R/W    | Forward decoded debug commands to the debug port. Present only when the `DEBUG_PORT_EN` parameter is set; otherwise reads 0 and is not writable |
| 31:5 | Reserved      | -      | Read 0, write 0                                                                                                                                 |

Writing 1 to SOFT_RESET resets the SPI slave state machine, aborts any
outstanding debug request (`GRPR-SPIS-019`), and **flushes both FIFOs**, so a
recovering driver does not inherit bytes from the transaction it just abandoned.
`STATUS` returns to its reset value and any pending multi-lane access is
discarded. It does not clear `IRQ_STATUS`: the flags record what already
happened, and firmware clears them with a W1C write when it has read them.

The bit is specified to self-clear after the reset completes; **the current RTL
does not self-clear it** — see `SPIS-SPEC-006`.

`DEBUG_PORT_EN` resets to 1, so this block forwards debug commands until
firmware opts out. That is safe because forwarding is not the same as
permitting: it gates only this block's forwarding, and the Debug Unit's own
consent gates (`GRPR-DBG-007`, `GRPR-DBG-022`) still decide whether a forwarded
command does anything. Both must permit an operation for it to take effect, and
`CTRL.LOCK_EN` in the Debug Unit is the gate that resets to 0 on a normally
strapped chip.

Note this bit exists only when the `DEBUG_PORT_EN` *parameter* is set; in a
build without the debug port it reads 0 and is not writable, so the reset value
above applies only to debug-capable builds.

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
That lets firmware answer a 4-byte debug response (`BUS_READ`, `DBG_READ`,
`BUS_STATUS` — see § Debug Command Encoding) with a single store instead of four.

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
- `SPIS-SPEC-007` — Whether one dummy byte is sufficient on `BUS_READ` and
  `DBG_READ` at the maximum `SCK` rate, given the debug-port round trip.
  Depends on the Debug Unit's response latency (`GRPR-DBG-034`/`-035`).
- `SPIS-SPEC-008` — **Resolved by the debug strap.** The pads still default to
  GPIO in the normal case, but holding GPIO pad 15 high at reset gives pads 0–3
  their SPI-slave alternate function in hardware
  ([`GRPR-SOC-024`](../Grouper%20SoC%20Specification.md#gpio-multiplexing-scheme)),
  so an external host can reach this block with no firmware involvement.
- `SPIS-SPEC-009` — The AHB error response is one cycle in the current RTL
  (`ahb_spi_s.sv`, with an existing `FIXME`), which is an AHB-Lite protocol
  violation; errors must be two cycles. **This is now load-bearing rather than
  cosmetic.** With `GRPR-SPIS-027` the block drives `HREADYOUT` low for the first
  time, so the error response and the lane stall share that signal and their
  precedence has to be defined: the error wins, and its second cycle presents
  `HREADYOUT` high on schedule regardless of the stall. The SPI Master resolves
  the same collision the same way.
- `SPIS-SPEC-010` — The 24-bit address captured by the legacy commands is
  currently read by nothing, so those commands do not yet address anything.
  Unrelated to the debug port, which uses its own 32-bit address phase.
- `SPIS-SPEC-011` — **The register map aliases across its 4 KiB window.** Only
  the low address bits are decoded, so the registers repeat — every 16 bytes with
  the current `HADDR[3:2]`, every 32 with the `HADDR[4:2]` this specification now
  requires. Harmless today, but it should be a stated decision rather than an
  accident; the SPI Master carries the same issue as `SPIM-ISSUE-020`. This ID was
  already referenced by `V-SPIS-DIR-005` in the verification plan before it was
  defined here.
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

See [SPI Slave Verification Plan](../../verification/blocks/SPI%20Slave%20Verification%20Plan.md) for the full item definitions and test list.
