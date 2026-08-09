# AHB UART

**Owner:** Sam
**Status:** RTL implemented (`hw/rtl/uart/`), integrated into `periph_ss` in the bring-up top level. Block-level DV started (`hw/dv/ahb_uart/`, `hw/dv/uvc/uart/`).
**Source:** [Schematic Review](../../Schematic%20Review.md) 

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence (UART is the boot-load peripheral), memory map, interconnect | [UART Verification Plan](../../verification/blocks/UART%20Verification%20Plan.md)

---

## Purpose

AHB-Lite UART peripheral. Two roles: (1) the boot-load path — the boot ROM receives the program image over this UART before the bank-switch reset hands control to RAM (see [Grouper SoC Specification § Boot Sequence](../Grouper%20SoC%20Specification.md#boot-sequence)); (2) a general-purpose async serial port available to firmware after boot.

## Protocols / Standards Conformity

- **Bus side:** AHB-Lite subordinate. A valid access is zero-wait-state; an invalid access (see [Invalid Access Rules](#invalid-access-rules-hresp1)) inserts a single wait state for the first cycle of the AHB-Lite two-cycle ERROR response. Byte/halfword/word accesses via `HSIZE` + byte-select, word-aligned 4-register map.
- **Serial side:** Async UART, LSB-first, 1 start bit (`0`) + 8 data bits + 1 stop bit (`1`), no parity. 8× oversampling with a resync window of ±1 sample around the bit-center sample point for baud-drift tolerance (`rx_resync_en`). No hardware flow control (no RTS/CTS).

## Key Functionality
- An 8N1 asynchronous serial port with a 4-entry FIFO in each direction, 
- a programmable baud divider, and a small control/status register set. 

### Feature overview/Use Case information (INFO)

#### Master enable and independent TX/RX enables

- `CTRL.ENABLE` is the block's master gate, gating the clock divider that provides baud ticks.
- `TX_EN` and `RX_EN` gate each direction independently.
- `TX_EN`/`RX_EN` leave the divider running, so the block still sees baud ticks.
- Dropping `TX_EN` parks `uart_tx` at the idle mark.
- Dropping `ENABLE` freezes the tick itself holds whatever level it was last driven to. See limitation [`L6`](#known-limitations). 
- The safe shutdown sequence is to poll `TX_ACTIVE=0` *first* and only then clear the enables — polling it after clearing `TX_EN` proves nothing, because `tx_active` is itself qualified by the transmit enable and reads 0 the moment `TX_EN` goes away.
- Neither enable touches a FIFO. With `TX_EN=0` firmware can still queue up to four bytes through `TXDATA` and they go out as soon as `TX_EN` is set; an `RX_EN=0` receiver stops capturing frames but leaves whatever is already in the RX FIFO readable. 
- Only `HRESETn` or an explicit flush clears a FIFO.

#### RX resynchronisation (`RX_RESYNC_EN`)

- The receiver phases itself on the falling edge of the start bit and then samples each bit at sample 4 of 8. 
- Across a 10-bit frame any baud mismatch between the two ends walks that sample point away from the bit centre.
- With `CTRL.RX_RESYNC_EN=1` (the reset value) the receiver watches for a `uart_rx` transition inside a ±1-sample window around each bit boundary (`sample_ctr` ∈ {7, 0, 1}) during the data and stop bits, and restarts the sample counter on it.T
- This resync feature allows at most one correction per bit, so a noisy line cannot repeatedly drag the sampling point around. The start bit is never resynced. 
- With `RX_RESYNC_EN=0` the phase is fixed for the whole frame by the start edge alone.

#### TX break generation (`TX_BREAK`)

- `CTRL.TX_BREAK` drives `uart_tx` low continuously — a space longer than a character frame, which the far end sees as a break. It is sampled only at frame boundaries.
- A break asserted mid-character lets that character finish and then takes hold.
- It is not a mid-character abort. 
- Queued bytes are not discarded while the break is asserted; they stay in the FIFO and go out after it clears. 
- On clearing, the  `CTRL.TX_BREAK`, the idle transition requires `uart_tx` to already be high, which forces at least one bit period of mark between the end of the break and the next start bit.

#### TX/RX FIFO flush (`FLUSH_TX_FIFO`, `FLUSH_RX_FIFO`)

- Both flush bits are write-1 one-shots: the write asserts the register bit for exactly one `HCLK` and it self-clears so it always reads back 0. 
- The pulse resets that FIFO's read/write pointers, its `full`/`empty` flags and its read-data register in a single cycle.
- A TX flush also inhibits the launch of a new frame on that baud tick, but it does not abort a character already in the shift register — that character completes on the wire.

#### RX break detection and sticky error flags

- `break_detect` is armed at the start-bit edge and AND-accumulated with the inverted line every baud tick, so it survives only if `uart_rx` never went high.
- A break is an all-zero character **and** a low stop bit. 
- When the stop-bit sample finds the line low with `break_detect` still set, the receiver enters a dedicated break state and stays there until the line returns high. - A break therefore always co-asserts `RX_FRAME_ERROR` — the low stop bit is a framing error in its own right — and pulses `rx_error_irq`.
- `STATUS.RX_FRAME_ERROR` and `STATUS.RX_BREAK` are sticky: set by the event, held until read. Both clear together on any `STATUS` read that selects byte lane 0. 
- Set beats clear — an event coincident with the clearing read leaves the bit set rather than losing it.
- A frame that fails either the start-bit or the stop-bit check is discarded: nothing is pushed to the RX FIFO and `rx_irq` does not pulse.

#### FIFO status reporting

`STATUS` exposes `TX_EMPTY`/`TX_FULL` and `RX_EMPTY`/`RX_FULL` straight from the two `small_sync_fifo` instances, plus `TX_ACTIVE`. These are the flow-control handles: firmware polls `TX_FULL` before writing `TXDATA` and `RX_EMPTY` before reading `RXDATA`, because getting either wrong is a bus error rather than a silent no-op.

- `TX_EMPTY` tracks the FIFO only — the transmitter pops a byte into its shift register as soon as it starts the frame, so `TX_EMPTY=1` means "nothing queued", not "nothing on the wire.
- `TX_ACTIVE` is the signal for the latter.
-  And `TX_ACTIVE` reads 0 as soon as the transmit enable is removed even if a character is still part-way out. so should be polled by firmware before touching the enables, not after.

#### Oversampling architecture (`OVERSAMPLE = 8`)

The `uart` core runs both directions from one baud tick at 8× the bit rate. The transmitter updates `uart_tx` once every 8 ticks (`sample_ctr == 0`); the receiver samples at tick 4 of 8 — the bit centre — and uses ticks 7/0/1 as its resync window. The 8× factor is why `CLK_DIV` divides to 8× the bit rate rather than to the bit rate itself (see [`GRPR-UART-010`](#parameters-and-configurations)), and it sets the receiver's static timing margin at roughly ±½ sample ≈ ±6 % of a bit period before resynchronisation is needed.

### Register interface

| ID | Requirement |
|---|---|
| `GRPR-UART-001` | The block shall expose 4 word-aligned AHB-Lite registers: `CTRL` (0x0, R/W), `STATUS` (0x4, R), `TXDATA` (0x8, W), `RXDATA` (0xC, R). |
| `GRPR-UART-002` | `CTRL` shall provide independent enables: `ENABLE`[0], `TX_EN`[1], `RX_EN`[2], `RX_RESYNC_EN`[3] (reset 1), `TX_BREAK`[4], `FLUSH_TX_FIFO`[5] (write-1-self-clearing), `FLUSH_RX_FIFO`[6] (write-1-self-clearing), and `CLK_DIV`[25:16] (10-bit baud divider, reset all-1s). |
| `GRPR-UART-003` | `STATUS` shall report `TX_EMPTY`[0], `TX_FULL`[1], `RX_EMPTY`[2], `RX_FULL`[3], `TX_ACTIVE`[4], `RX_FRAME_ERROR`[5], `RX_BREAK`[6]. `TX_EMPTY`/`TX_FULL` reflect the TX FIFO only, not the shift register; `TX_ACTIVE` is `enable && tx_en && state != ST_IDLE` and therefore reads 0 whenever the transmit enable is clear, regardless of what is on the wire. |
| `GRPR-UART-004` | Writing `TXDATA` shall push a byte into a 4-entry TX FIFO; the write shall be rejected with `HRESP` error if `TX_FULL`. |
| `GRPR-UART-005` | Reading `RXDATA` shall pop a byte from a 4-entry RX FIFO; the read shall be rejected with `HRESP` error if `RX_EMPTY`. |
| `GRPR-UART-006` | Writes to `STATUS` and reads/writes that target invalid combinations (write to `RXDATA`, write to `STATUS`) shall be rejected with `HRESP` error. |
| `GRPR-UART-025` | Register decode shall use `HADDR[3:2]` only. The 4-register map therefore aliases every 16 bytes throughout whatever region the interconnect assigns to the block; `0x10` is `CTRL`, `0x14` is `STATUS`, and so on. |
| `GRPR-UART-026` | Reads of write-only `TXDATA`, and reads of any unimplemented bit of `CTRL`/`STATUS`/`RXDATA`, shall return 0 and shall **not** raise an error response. `HRDATA` shall be 0 when no read is in its data phase. |

### Enables and gating

| ID | Requirement |
|---|---|
| `GRPR-UART-014` | `CTRL.ENABLE=0` shall stop the baud-tick generator and with it both state machines: no state, sample-counter or `uart_tx` update occurs, and no frame is transmitted or received. It shall not clear the FIFOs, `CTRL`, or the sticky `STATUS` flags. Clearing `ENABLE` is a **freeze, not a reset** — see limitation `L6`. |
| `GRPR-UART-015` | `TX_EN` and `RX_EN` shall gate only their own direction (`enable && tx_en`, `enable && rx_en`) and shall not affect FIFO contents or FIFO status flags. `TXDATA` writes shall still enqueue with `TX_EN=0`, and the RX FIFO shall remain readable with `RX_EN=0`. With `ENABLE=1`, clearing `TX_EN` shall park `uart_tx` at the idle mark within one baud tick. |
| `GRPR-UART-016` | With `ENABLE` held set, asserting `TX_EN`/`RX_EN` shall force that direction's state machine and sample counter to their idle state (TX `ST_IDLE`, RX `ST_WAIT_START`) on the first baud tick, so enabling during line activity cannot begin mid-character. |

### Serial transmit

| ID | Requirement |
|---|---|
| `GRPR-UART-008` | `TX_BREAK` shall force the TX line low continuously (break transmission), overriding normal FIFO-driven transmission. |
| `GRPR-UART-018` | `TX_BREAK` shall be sampled only at frame boundaries (`ST_IDLE`, `ST_STOP_BIT`): a character already in progress shall complete before the break takes effect. Bytes queued during a break shall be retained and transmitted after it clears, and `uart_tx` shall be held at mark for at least one bit period between break de-assertion and the next start bit. |
| `GRPR-UART-019` | `FLUSH_TX_FIFO`/`FLUSH_RX_FIFO` shall assert for exactly one `HCLK`, read back 0, and reset the addressed FIFO's pointers, `full`/`empty` flags and read-data register. A TX flush shall inhibit the launch of a new frame but shall not abort a character already in the shift register. |

### Serial receive

| ID | Requirement |
|---|---|
| `GRPR-UART-007` | The block shall detect and flag framing errors (bad start or stop bit) via `RX_FRAME_ERROR`, and shall detect a break condition (sustained line-low past a stop bit) via `RX_BREAK`. |
| `GRPR-UART-017` | With `RX_RESYNC_EN=1`, during the data and stop bits the receiver shall restart its sample counter on a `uart_rx` transition falling inside the ±1-sample window around a bit boundary (`sample_ctr` ∈ {7, 0, 1}), at most once per bit. The start bit shall never be resynchronised. With `RX_RESYNC_EN=0`, bit phase shall be fixed for the whole frame by the start-bit edge. |
| `GRPR-UART-020` | `RX_BREAK` shall assert only when `uart_rx` is low continuously from the start-bit edge through the stop-bit sample. The receiver shall then hold a break state until the line returns high. A break shall always also assert `RX_FRAME_ERROR` and pulse `rx_error_irq`. |
| `GRPR-UART-021` | `RX_FRAME_ERROR` and `RX_BREAK` shall be sticky, and shall **both** clear on any `STATUS` read selecting byte lane 0. A new event coincident with that read shall leave the bit set. |
| `GRPR-UART-022` | A frame failing the start-bit or stop-bit check shall be discarded: no byte shall be pushed to the RX FIFO and `rx_irq` shall not pulse. |
| `GRPR-UART-024` | The receiver shall sample each bit at sample 4 of `OVERSAMPLE`=8 (the bit centre); the transmitter shall update `uart_tx` once per 8 baud ticks, at `sample_ctr == 0`. |

### Interrupts

| ID | Requirement |
|---|---|
| `GRPR-UART-023` | `rx_irq` shall pulse for one `HCLK` on each successfully received byte and `rx_error_irq` for one `HCLK` on each RX framing error (including a break). Both shall be level-0 otherwise. There is no interrupt enable, mask or status-clear register, and no TX-side interrupt — firmware must poll `STATUS.TX_EMPTY`/`TX_FULL`. |


## Block Diagram
```

                  +--------------------------------------------+
                  |                  ahb_uart                  |
                  |                                            |
                  |                       +------------------+ |  uart_tx
                  |                       |   uart (core)    | |  -------->
                  |                       |                  | |   
                  |                       | +--------------+ | |
   AHB-Lite       | +-----------------+   | | uart_clk_div | | |  uart_rx
Slave Interface   | |  Register bank  |   | +--------------+ | |  <--------
                  | |                 |   |                  | |   
    <-------->    | | CTRL / STATUS / |   | +---------+      | |
                  | | TXDATA / RXDATA |   | | uart_tx |      | |  
                  | +-----------------+   | +---------+      | |  
                  |                       |                  | |
                  |                       | +---------+      | | IRQs
                  |                       | | uart_rx |      | | -------->
                  |                       | +---------+      | |
                  |                       +------------------+ |
                  +--------------------------------------------+
```
## uArch Diagram
```

                  +-----------------------------------------------------------------------------------+
                  |                                      ahb_uart                                     |
                  |                                                                                   |
                  |                       +---------------------------------------------------------+ |
                  |                       |                       uart (core)                       | |
                  |                       |                                                         | |
                  |                       | +--------------+                                        | |
                  |                       | | uart_clk_div |                                        | |
                  |                       | +--------------+                                        | |
                  |                       |                                                         | |
                  |                       | +------------------------------------------------+      | |
                  |                       | |                    uart_tx                     |      | |
                  |                       | |                                                |      | |
AHB-Lite          |                       | | tx_data,tx_write                               |      | |  uart_tx
Master            |                       | |        |                                       |      | |  -------->
                  |                       | |        v                                       |      | |    (TX serial out)
HADDR,HBURST,     |                       | |   [ TX FIFO ]                                  |      | |
HMASTLOCK,HPROT,  | +-----------------+   | |        |                                       |      | |  uart_rx
HSIZE,HTRANS,     | |  Register bank  |   | |        v                                       |      | |  <--------
HWDATA,HWRITE,    | |                 |-->| |   [ shift_reg ] --> [ serializer ] --> uart_tx |      | |    (RX serial in)
HREADYIN,HSEL     | | CTRL / STATUS / |<--| |                                                |      | |
  -------->       | | TXDATA / RXDATA |   | | tx_full, tx_empty, tx_active --> STATUS        |      | |  rx_irq
                  | +-----------------+   | +------------------------------------------------+      | |  -------->
  <--------       |                       |                                                         | |
HRDATA,           |                       | +-----------------------------------------------------+ | |  rx_error_irq
HREADYOUT,HRESP   |                       | |                       uart_rx                       | | |  -------->
                  |                       | |                                                     | | |
                  |                       | | uart_rx                                             | | |
                  |                       | |    |                                                | | |
                  |                       | |    v                                                | | |
                  |                       | | [ sync ] --> [ shift_reg ]                          | | |
                  |                       | |                     |                               | | |
                  |                       | |                     v                               | | |
                  |                       | |               [ RX FIFO ]   -->  rx_data            | | |
                  |                       | |                                                     | | |
                  |                       | | rx_full, rx_empty,                                  | | |
                                          | |   rx_frame_error,rx_break --> STATUS                | | |
                  |                       | +-----------------------------------------------------+ | |
                  |                       +---------------------------------------------------------+ |
                  +-----------------------------------------------------------------------------------+
```

## Parameters and Configurations

| ID | Requirement |
|---|---|
| `GRPR-UART-010` | `CLK_DIV_BITS = 10` (RTL parameter): baud tick period = `(CTRL.CLK_DIV + 1)` `HCLK` cycles; one UART bit period = 8 baud ticks (`OVERSAMPLE = 8`). Effective baud rate = `HCLK / (8 × (CLK_DIV + 1))`. |
| `GRPR-UART-011` | TX and RX FIFOs are each 4 entries deep (`FIFO_DEPTH = 4`, power-of-2 required by `small_sync_fifo`), 8 bits wide (`DATA_WIDTH = 8`). |

## IOs and External Interfaces

| Port | Direction | Width | Description |
|---|---|---|---|
| `HADDR`/`HBURST`/`HMASTLOCK`/`HPROT`/`HSIZE`/`HTRANS`/`HWDATA`/`HWRITE` | in | — | AHB-Lite master-driven signals |
| `HRDATA`/`HREADYOUT`/`HRESP` | out | — | AHB-Lite subordinate response |
| `HREADYIN`/`HSEL` | in | — | AHB-Lite decoder signals |
| `uart_tx` | out | 1 | Serial TX line |
| `uart_rx` | in | 1 | Serial RX line (async, synchronized internally) |
| `rx_irq` | out | 1 | Pulses on byte received (mirrors `uart` core's `received`) |
| `rx_error_irq` | out | 1 | Pulses on RX frame error |

## Clocking Strategy

`GRPR-UART-012` THe IP shall operate on a single clock domain (`HCLK`).

## Reset Strategy

`GRPR-UART-013` THe IP shall prove a single active-low reset (`HRESETn`), that is asynchronously asserted and synchronous de-asserted.

## CDC Strategy

`GRPR-UART-009` `uart_rx` shall be passed through a 2-stage synchronizer before use. All other signals are synchronous to `HCLK`. No CDC is needed on the AHB-Lite side (single clock domain bus).

## Performance Targets

### Standard baud rates at 16 MHz

| HCLK | target baud rate| CLK_DIV+1 (ideal) | actual | error |
|---|---|---|---|---|
| 16MHz | 2400 | 833.33 | 2400.96 (÷833) | +0.04% |
| 16MHz | 4800 | 416.67 | 4796.16 (÷417) | −0.08% |
| 16MHz | 9600 | 208.33 | 9615.38 (÷208) | +0.16% |
| 16MHz | 19200 | 104.17 | 19230.8 (÷104) | +0.16% |
| 16MHz | 38400 | 52.08 | 38461.5 (÷52) | +0.16% |
| 16MHz | 57600 | 34.72 | 57142.9 (÷35) | −0.79% |
| 16MHz | 76800 | 26.04 | 76923.1 (÷26) | +0.16% |
| 16MHz | 115200 | 17.36 | 117647 (÷17) |  +2.12% |

### Exact (binary-divisible) rates at 16 MHz
| HCLK | target | CLK_DIV+1 (ideal) | actual | error |
|---|---|---|---|---|
| 16MHz | 2000000 | 1 | 2000000 (÷1) | 0.00% |
| 16MHz | 1000000 | 2 | 1000000 (÷2) | 0.00% |
| 16MHz | 500000 | 4 | 500000 (÷4) | 0.00% |
| 16MHz | 250000 | 8 | 250000 (÷8) | 0.00% |
| 16MHz | 125000 | 16 | 125000 (÷16) | 0.00% |
| 16MHz | 62500 | 32 | 62500 (÷32) | 0.00% |
| 16MHz | 31250 | 64 | 31250 (÷64) | 0.00% |
| 16MHz | 15625 | 128 | 15625 (÷128) | 0.00% |

## AHB3-Lite Interface Behavior

- A valid transfer completes with no wait states (`HREADYOUT=1`).
- An invalid transfer is answered with the AMBA 3 AHB-Lite **two-cycle ERROR response**: `HRESP` high for two cycles, `HREADYOUT` low on the first and high on the second, giving the master a cycle to cancel the transfer already in its address phase. The address-phase capture is held while `HREADYOUT` is low, so the stalled transfer is sampled exactly once.
- An access is taken when `HREADYIN && HSEL && HTRANS ∈ {NONSEQ, SEQ}`. `HBURST`, `HPROT` and `HMASTLOCK` are ignored; a burst is serviced as a sequence of independent single transfers.

| ID | Requirement |
|---|---|
| `GRPR-UART-028` | An invalid access shall be answered with the two-cycle AHB-Lite ERROR response — `(HREADYOUT, HRESP)` = `(0,1)` then `(1,1)` — and the address-phase capture shall be held while `HREADYOUT` is low, so the stalled transfer is applied exactly once and the transfer following it is neither lost nor duplicated. |
| `GRPR-UART-029` | The `RXDATA` pop and the empty-check that decides its error response shall both be taken in the **address** phase and registered into the data phase, so a read of the last byte in the RX FIFO completes normally even though `RX_EMPTY` is already high by its data phase. |
| `GRPR-UART-027` | `HRDATA` shall return the full 32-bit register contents irrespective of `HSIZE`; the block does not narrow or lane-align read data, and the master is expected to extract its own byte lane. |

## Register Map (base + offset)
- `0x00` (`CTRL`,   RW)
- `0x04` (`STATUS`,  RO)
- `0x08` (`TDATA`,   WO)
- `0x0C` (`RXDATA`,  RO)

### CTRL Register (`0x00`, RW)
- `bit[0]`  `enable`
- `bit[1]`  `tx_en`
- `bit[2]`  `rx_en`
- `bit[3]`  `rx_resync_en`
- `bit[4]`  `tx_break`
- `bit[5]`  `flush_tx_fifo`  (pulse / one-shot)
- `bit[6]`  `flush_rx_fifo`  (pulse / one-shot)
- `bit[25:16]` `clk_div[9:0]`

### STATUS Register (`0x04`, RO)
- `bit[0]` `tx_empty`
- `bit[1]` `tx_full`
- `bit[2]` `rx_empty`
- `bit[3]` `rx_full`
- `bit[4]` `tx_active`
- `bit[5]` `rx_frame_error` (sticky)
- `bit[6]` `rx_break`       (sticky)

### TXDATA Register (`0x08`, WO)
- `bit[7:0]` data written into TX FIFO when not full

### RXDATA Register (`0x0C`, RO)
- `bit[7:0]` data read from RX FIFO when not empty

## Invalid Access Rules (`HRESP=1`)
- Write to `STATUS`  is invalid
- Write to `RXDATA`  is invalid
- Write to `TXDATA`  is invalid when TX FIFO is full
- Read from `RXDATA` is invalid when RX FIFO is empty

## Known Limitations

Behaviours found in the RTL that are *not* requirements — they are what the block currently does, and each is either a latent bug or a deliberate omission worth recording so nobody re-derives it from scratch.

| # | Limitation | Consequence |
|---|---|---|
| `L1` | **A byte or halfword write to `CTRL` clobbers `CLK_DIV`.** `ahb_uart.sv` gates the whole `CTRL` write on `byte_select_r[0]` and then assigns *every* field from `HWDATA`, including `CLK_DIV[25:16]`. There is no per-lane masking. | Contradicts the byte/halfword access promise in `GRPR-UART-001`. Latent today only because `sw/src/uart/uart.c` always writes `CTRL` as a word. Pinned by the `expect_fail` test `V-UART-DIR-002a`, which starts passing if the RTL is fixed. |
| `L2` | **A `TXDATA` write that does not cover byte lane 0 is silently dropped.** `tx_write` requires `byte_select_r[0]`, but the invalid-access check only tests `TX_FULL`. A byte write to `0x9`/`0xA`/`0xB` is answered OKAY and pushes nothing. | Silent data loss rather than an error response. Firmware writes lane 0 (`uart_tx()` casts to `volatile uint8_t*` at the base offset), so it is not hit today. |
| `L3` | **No RX overrun detection.** A byte arriving while `RX_FULL` still asserts `fifo_write`; `small_sync_fifo` holds the write pointer but performs `memory[wptr] <= wdata` unconditionally, and `wptr == rptr` when full — so the *oldest unread* entry is overwritten. `rx_irq` still pulses and no status bit records it. | Overrun corrupts the FIFO's oldest entry instead of dropping the newest, and is undetectable from `STATUS`. Adding an `RX_OVERRUN` sticky bit would need a new `STATUS` bit and a `GRPR-UART-*` requirement. **Open item.** |
| `L4` | **`HBURST`, `HPROT`, `HMASTLOCK` are unused inputs**, and `HTRANS_SEQ` is accepted identically to `HTRANS_NONSEQ`. | Correct for a 4-register slave with no burst semantics, but it means the block cannot distinguish a stray `SEQ` beat from a legitimate single. Recorded, not planned for change. |
| `L5` | **`sync` resets `rx_sync` to 0** (`RESET_VALUE='0`) while an idle serial line is high, so `uart_rx` reads low for the two cycles after reset release. | Benign as built: the block is disabled out of reset (`ctrl_enable=0`) and enabling takes an AHB write, by which time the synchroniser has settled. It would become a false start bit if `ENABLE` ever reset to 1. |
| `L6` | **Clearing `CTRL.ENABLE` freezes the block rather than parking it.** `uart_clk_div` holds `ctr` when disabled, and `ctr == 0` for only 1 cycle in `CLK_DIV+1`, so the baud tick almost always freezes low. Everything gated on it freezes too: `uart_tx` holds its last driven level, and the `enable_r` edge detect in `uart_tx.sv`/`uart_rx.sv` never clears, so re-enabling resumes the *same* character mid-way instead of restarting from idle. (With `CLK_DIV=0` the tick is permanently high and the block does park and restart cleanly — the one case that hides this.) | Disabling mid-character can leave `uart_tx` stuck low, which the far end reads as a break, and re-enabling emits the tail of a stale character. Firmware should clear `TX_EN`/`RX_EN`, poll `TX_ACTIVE=0`, and only then clear `ENABLE`. **Open item** — a one-line fix is to make `enable_r`/`uart_tx` in `uart_tx.sv` update on every clock rather than only on `uart_clk_en`. |

## Size Estimate

Not yet documented in the source deck or estimated from synthesis. **Open item.**

## Open Items

- "Size Estimate".
- `L6` — decide whether clearing `ENABLE` should park the block or keep freezing it. Freezing mid-character puts a break on the wire; this is the most likely of the limitations to bite real firmware.
- `L3` — decide whether an `RX_OVERRUN` sticky status bit is worth the area before tape-out. Today an overrun is silent *and* corrupting.
- `L1` — per-lane masking of the `CTRL` write, or an explicit spec carve-out saying `CTRL` is word-access only.


## Verification Cross-Reference

`STM`/`CHK`/`COV` items belong to the pyuvm flow and are blocked on a scoreboard that does not exist yet. `DIR` items are the directed cocotb bench, which runs today.

| Req ID | pyuvm items | Directed items |
|---|---|---|
| `GRPR-UART-001` | `V-UART-STM-001`, `V-UART-CHK-001` | `V-UART-DIR-001..003`, `002a` |
| `GRPR-UART-002` | `V-UART-STM-002`, `V-UART-CHK-002`, `V-UART-COV-001` | `V-UART-DIR-004..007` |
| `GRPR-UART-003` | `V-UART-CHK-003`, `V-UART-COV-002` | `V-UART-DIR-008..010` |
| `GRPR-UART-004` | `V-UART-STM-003`, `V-UART-CHK-004` | `V-UART-DIR-011..013` |
| `GRPR-UART-005` | `V-UART-STM-004`, `V-UART-CHK-005` | `V-UART-DIR-014..016` |
| `GRPR-UART-006` | `V-UART-STM-005`, `V-UART-CHK-006` | `V-UART-DIR-017` |
| `GRPR-UART-007` | `V-UART-STM-006`, `V-UART-CHK-007` | `V-UART-DIR-018..021` |
| `GRPR-UART-008` | `V-UART-STM-007`, `V-UART-CHK-008` | `V-UART-DIR-022..023` |
| `GRPR-UART-009` | `V-UART-CHK-009` | — structural, needs CDC lint |
| `GRPR-UART-010` | `V-UART-STM-008`, `V-UART-COV-003` | `V-UART-DIR-024..025` |
| `GRPR-UART-011` | `V-UART-STM-009`, `V-UART-CHK-010` | `V-UART-DIR-026..027` |
| `GRPR-UART-012` | — | — structural, established by inspection |
| `GRPR-UART-013` | — | — needs an SoC-wide reset-strategy review |
| `GRPR-UART-014` | `V-UART-STM-010`, `V-UART-CHK-011` | `V-UART-DIR-030` |
| `GRPR-UART-015` | `V-UART-STM-010`, `V-UART-CHK-011` | `V-UART-DIR-031..032` |
| `GRPR-UART-016` | `V-UART-STM-010` | `V-UART-DIR-033` |
| `GRPR-UART-017` | `V-UART-STM-011`, `V-UART-CHK-012`, `V-UART-COV-004` | `V-UART-DIR-034..035` |
| `GRPR-UART-018` | `V-UART-STM-007`, `V-UART-CHK-008` | `V-UART-DIR-023`, `036` |
| `GRPR-UART-019` | `V-UART-STM-002`, `V-UART-CHK-002` | `V-UART-DIR-006..007`, `037` |
| `GRPR-UART-020` | `V-UART-STM-006`, `V-UART-CHK-007` | `V-UART-DIR-020`, `038` |
| `GRPR-UART-021` | `V-UART-CHK-013` | `V-UART-DIR-010`, `039` |
| `GRPR-UART-022` | `V-UART-CHK-014` | `V-UART-DIR-018..019` |
| `GRPR-UART-023` | `V-UART-CHK-015` | `V-UART-DIR-021` |
| `GRPR-UART-024` | `V-UART-STM-008`, `V-UART-COV-003` | `V-UART-DIR-018`, `024..025`, `040` |
| `GRPR-UART-025` | `V-UART-CHK-001` | `V-UART-DIR-001` |
| `GRPR-UART-026` | `V-UART-CHK-001` | `V-UART-DIR-001`, `003` |
| `GRPR-UART-027` | `V-UART-STM-001` | `V-UART-DIR-002` |
| `GRPR-UART-028` | `V-UART-CHK-016` | `V-UART-DIR-028..029` |
| `GRPR-UART-029` | `V-UART-CHK-005` | `V-UART-DIR-014` |
| `L1` (limitation) | — | `V-UART-DIR-002a` (`expect_fail`) |
| `L2` (limitation) | — | `V-UART-DIR-041` |
| `L3` (limitation) | `V-UART-COV-005` | `V-UART-DIR-042` |
| `L6` (limitation) | `V-UART-CHK-011` | `V-UART-DIR-043` |

See [UART Verification Plan](../../verification/blocks/UART%20Verification%20Plan.md) for the full item definitions and test list.
