#ifndef __UART_H__
#define __UART_H__

#include <stdint.h>
#include <stdbool.h>

// Base address of the AHB UART register block.
// Must match the UART window in hw/rtl/ahb_interconnect_ss.sv.
#define AHB_UART_BASE  0x00003000

// Core clock the baud divisor is computed against. This must match the clock
// the SoC is actually run at, or every byte goes out at the wrong baud rate -
// the top-level testbench asserts this against its own CLK_FREQ localparam
// (hw/tb/top/grouper_soc_hello_tb.sv).
#define SYS_CLK_HZ     10000000

// Baud rate init_uart() configures.
#define UART_BAUD_RATE 19200

// Word offsets into the register block. These match the ADDR_* localparams
// in hw/rtl/uart/ahb_uart.sv (decoded from HADDR[3:2]).
#define UART_CTRL_ADDR   0
#define UART_STATUS_ADDR 1
#define UART_TXDATA_ADDR 2
#define UART_RXDATA_ADDR 3

// Control register. Bit positions taken from the ADDR_CTRL write path in
// hw/rtl/uart/ahb_uart.sv. Note bits 5/6 (the FIFO flush strobes) are
// write-only-self-clearing in the RTL: they are accepted on a write but do
// not appear in the ADDR_CTRL read-back.
typedef union {
    uint32_t raw;
    struct {
        uint32_t ctrl_enable        : 1;  // bit 0
        uint32_t ctrl_tx_en         : 1;  // bit 1
        uint32_t ctrl_rx_en         : 1;  // bit 2
        uint32_t ctrl_rx_resync_en  : 1;  // bit 3
        uint32_t ctrl_tx_break      : 1;  // bit 4
        uint32_t ctrl_flush_tx_fifo : 1;  // bit 5 (WOSC, write-only)
        uint32_t ctrl_flush_rx_fifo : 1;  // bit 6 (WOSC, write-only)
        uint32_t reserved0          : 9;  // bits 7-15
        uint32_t ctrl_clk_div       : 10; // bits 16-25 (CLK_DIV_BITS)
        uint32_t reserved1          : 6;  // bits 26-31
    } s;
} uart_ctrl_t;

// Status register. Bit positions taken from the ADDR_STATUS HRDATA
// construction in hw/rtl/uart/ahb_uart.sv.
typedef union {
    uint32_t raw;
    struct {
        uint32_t status_tx_empty       : 1; // bit 0
        uint32_t status_tx_full        : 1; // bit 1
        uint32_t status_rx_empty       : 1; // bit 2
        uint32_t status_rx_full        : 1; // bit 3
        uint32_t status_tx_active      : 1; // bit 4
        uint32_t status_rx_frame_error : 1; // bit 5
        uint32_t status_rx_break       : 1; // bit 6
        uint32_t reserved              : 25;
    } s;
} uart_status_t;

void init_uart(void);
void uart_tx(uint8_t c);
uint8_t uart_rx(void);
uart_status_t uart_status(void);

#endif // __UART_H__
