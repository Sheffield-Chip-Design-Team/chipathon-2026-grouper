# AHB UART

**Owner:** Sam
**Status:** RTL implemented (`hw/rtl/uart/`), integrated into `periph_ss` in the bring-up top level. Block-level DV started (`hw/dv/ahb_uart/`, `hw/dv/uvc/uart/`).
**Source:** [Schematic Review](../../Schematic%20Review.md) §"Block-Level Design Checklists → 1. AHB UART" lists this block's checklist fields as *(not yet documented)*. The requirements below are reverse-derived from the actual RTL (`hw/rtl/uart/uart.sv`, `uart_tx.sv`, `uart_rx.sv`, `uart_clk_div.sv`, `ahb_uart.sv`) rather than the deck, since the deck has no content for this block yet. Cross-check against RTL before trusting any field here that RTL later changes.

**Related:** [Grouper SoC Specification](../Grouper%20SoC%20Specification.md) — boot sequence (UART is the boot-load peripheral), memory map, interconnect | [UART Verification Plan](../../verification/blocks/UART%20Verification%20Plan.md)

---

## Purpose

AHB-Lite UART peripheral. Two roles: (1) the boot-load path — the boot ROM receives the program image over this UART before the bank-switch reset hands control to RAM (see [Grouper SoC Specification § Boot Sequence](../Grouper%20SoC%20Specification.md#boot-sequence)); (2) a general-purpose async serial port available to firmware after boot.

## Protocols / Standards Conformity

- **Bus side:** AHB-Lite subordinate. Zero-wait-state (`HREADYOUT` tied high), byte/halfword/word accesses via `HSIZE` + byte-select, word-aligned 4-register map.
- **Serial side:** Async UART, LSB-first, 1 start bit (`0`) + 8 data bits + 1 stop bit (`1`), no parity. 8× oversampling with a resync window of ±1 sample around the bit-center sample point for baud-drift tolerance (`rx_resync_en`). No hardware flow control (no RTS/CTS).

## Key Functionality

# UART Features
- Configurable UART enable and independent TX/RX enables
- RX resynchronization enable (`rx_resync_en`)
- TX break generation (`tx_break`)
- Flush controls for TX/RX FIFOs (write-one-shot control bits)
- RX break detection and sticky RX error/break status flags
- FIFO status reporting: empty/full for TX and RX
- Oversampling architecture inside UART core (`OVERSAMPLE=8`)

| ID | Requirement |
|---|---|
| `GRPR-UART-001` | The block shall expose 4 word-aligned AHB-Lite registers: `CTRL` (0x0, R/W), `STATUS` (0x4, R), `TXDATA` (0x8, W), `RXDATA` (0xC, R). |
| `GRPR-UART-002` | `CTRL` shall provide independent enables: `ENABLE`[0], `TX_EN`[1], `RX_EN`[2], `RX_RESYNC_EN`[3] (reset 1), `TX_BREAK`[4], `FLUSH_TX_FIFO`[5] (write-1-self-clearing), `FLUSH_RX_FIFO`[6] (write-1-self-clearing), and `CLK_DIV`[25:16] (10-bit baud divider, reset all-1s). |
| `GRPR-UART-003` | `STATUS` shall report `TX_EMPTY`[0], `TX_FULL`[1], `RX_EMPTY`[2], `RX_FULL`[3], `TX_ACTIVE`[4], `RX_FRAME_ERROR`[5], `RX_BREAK`[6]. |
| `GRPR-UART-004` | Writing `TXDATA` shall push a byte into a 4-entry TX FIFO; the write shall be rejected with `HRESP` error if `TX_FULL`. |
| `GRPR-UART-005` | Reading `RXDATA` shall pop a byte from a 4-entry RX FIFO; the read shall be rejected with `HRESP` error if `RX_EMPTY`. |
| `GRPR-UART-006` | Writes to `STATUS` and reads/writes that target invalid combinations (write to `RXDATA`, write to `STATUS`) shall be rejected with `HRESP` error. |
| `GRPR-UART-007` | The block shall detect and flag framing errors (bad start or stop bit) via `RX_FRAME_ERROR`, and shall detect a break condition (sustained line-low past a stop bit) via `RX_BREAK`. |
| `GRPR-UART-008` | `TX_BREAK` shall force the TX line low continuously (break transmission), overriding normal FIFO-driven transmission. |


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
- No wait states from slave (`HREADYOUT=1`)

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

## Size Estimate

Not yet documented in the source deck or estimated from synthesis. **Open item.**

## Open Items

- "Size Estimate".
- Boot-load baud rate / target throughput not specified anywhere yet — needed to validate the boot-sequence timing budget in the top-level spec.

- `ahb_uart.sv` carries a stale header comment (lines 1–11) describing a "BCD Converter" register map — leftover from an earlier/different module template. The actual implementation below it (the 4-register UART map documented above) is what's real; the comment should be deleted by whoever next touches that file.

- `STATUS.RX_FRAME_ERROR`/`RX_BREAK` read-clear behavior: the RTL clears `status_rx_frame_error` on a `STATUS` read but does not appear to clear 

`status_rx_break` the same way (`hw/rtl/uart/ahb_uart.sv` lines 240–250) — worth a directed test to confirm intended behavior before relying on it.

## Verification Cross-Reference

| Req ID | Verification Item(s) |
|---|---|
| `GRPR-UART-001` | `V-UART-STM-001`, `V-UART-CHK-001` |
| `GRPR-UART-002` | `V-UART-STM-002`, `V-UART-CHK-002`, `V-UART-COV-001` |
| `GRPR-UART-003` | `V-UART-CHK-003`, `V-UART-COV-002` |
| `GRPR-UART-004` | `V-UART-STM-003`, `V-UART-CHK-004` |
| `GRPR-UART-005` | `V-UART-STM-004`, `V-UART-CHK-005` |
| `GRPR-UART-006` | `V-UART-STM-005`, `V-UART-CHK-006` |
| `GRPR-UART-007` | `V-UART-STM-006`, `V-UART-CHK-007` |
| `GRPR-UART-008` | `V-UART-STM-007`, `V-UART-CHK-008` |
| `GRPR-UART-009` | `V-UART-CHK-009` |
| `GRPR-UART-010` | `V-UART-STM-008`, `V-UART-COV-003` |
| `GRPR-UART-011` | `V-UART-STM-009`, `V-UART-CHK-010` |

See [UART Verification Plan](../../verification/blocks/UART%20Verification%20Plan.md) for the full item definitions and test list.
