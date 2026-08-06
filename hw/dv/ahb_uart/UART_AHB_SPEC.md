# UART + AHB3 Simple Specification

This spec is derived from `hw/rtl/uart/ahb_uart.sv`, `uart.sv`, `uart_tx.sv`, and `uart_rx.sv`.

## Overview
- Peripheral: `ahb_uart`
- Bus: AHB3-Lite slave, single-cycle transfers (`HREADYOUT=1`)
- Data width: 32-bit bus, UART payload width 8-bit
- UART core: TX + RX with FIFOs and programmable clock divider


- DV strategy: one AHB-driven sanity test that writes `TXDATA`, stimulates `uart_rx`, and reads `RXDATA`
- Interrupts:
  - `rx_irq`: pulse when a byte is received (wired from `received`)
  - `rx_error_irq`: pulse on RX frame error (wired from `rx_frame_error`)

## UART Features
- Configurable UART enable and independent TX/RX enables
- RX resynchronization enable (`rx_resync_en`)
- TX break generation (`tx_break`)
- Flush controls for TX/RX FIFOs (write-one-shot control bits)
- RX break detection and sticky RX error/break status flags
- FIFO status reporting: empty/full for TX and RX
- Oversampling architecture inside UART core (`OVERSAMPLE=8`)

## AHB3-Lite Interface Behavior
- Access is valid when `HREADYIN && HSEL && (HTRANS != HTRANS_IDLE)`
- Read and write operations are accepted in address phase and acted on in data phase
- Byte-lane decode uses `generate_byte_select_32(HSIZE, HADDR[1:0])`
- Register decode uses `HADDR[3:2]` (word addressing)
- Error response (`HRESP=1`) on invalid accesses
- No wait states from slave (`HREADYOUT=1`)

## Register Map (base + offset)
- `0x00` (`ADDR_CTRL`, RW)
- `0x04` (`ADDR_STATUS`, RO)
- `0x08` (`ADDR_TXDATA`, WO)
- `0x0C` (`ADDR_RXDATA`, RO)

### CTRL Register (`0x00`, RW)
- `bit[0]`  `enable`
- `bit[1]`  `tx_en`
- `bit[2]`  `rx_en`
- `bit[3]`  `rx_resync_en`
- `bit[4]`  `tx_break`
- `bit[5]`  `flush_tx_fifo` (pulse / one-shot)
- `bit[6]`  `flush_rx_fifo` (pulse / one-shot)
- `bit[25:16]` `clk_div[9:0]`

### STATUS Register (`0x04`, RO)
- `bit[0]` `tx_empty`
- `bit[1]` `tx_full`
- `bit[2]` `rx_empty`
- `bit[3]` `rx_full`
- `bit[4]` `tx_active`
- `bit[5]` `rx_frame_error` (sticky)
- `bit[6]` `rx_break` (sticky)

### TXDATA Register (`0x08`, WO)
- `bit[7:0]` data written into TX FIFO when not full

### RXDATA Register (`0x0C`, RO)
- `bit[7:0]` data read from RX FIFO when not empty

## Invalid Access Rules (`HRESP=1`)
- Write to `STATUS` is invalid
- Write to `RXDATA` is invalid
- Write to `TXDATA` is invalid when TX FIFO is full
- Read from `RXDATA` is invalid when RX FIFO is empty

## Notes from RTL
- In `ahb_uart.sv`, `status_rx_break` appears intended as read-clear but currently is not explicitly cleared in the status-read block (implementation detail to verify/fix separately)
