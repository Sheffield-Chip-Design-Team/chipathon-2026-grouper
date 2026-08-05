#include <stdint.h>
#include <stdbool.h>

#include "uart.h"
#include "debug.h"

// AHB_UART_BASE and the UART_*_ADDR register offsets now live in uart.h.

static volatile uint32_t *const UART_REGS = (volatile uint32_t*) AHB_UART_BASE;

// +0.5 to round to nearest integer
// *8 as we have 8x oversampling
static const int clk_div = 10e+6/(19200*8) + 0.5;

void init_uart(void) {
    uart_ctrl_t x = {0};
    x.s.ctrl_enable = 1;
    x.s.ctrl_tx_en = 1;
    x.s.ctrl_clk_div = clk_div;
    x.s.ctrl_flush_tx_fifo = 1;
    x.s.ctrl_rx_en = 1;
    x.s.ctrl_rx_resync_en = 1;
    x.s.ctrl_flush_rx_fifo = 1;
    UART_REGS[UART_CTRL_ADDR] = x.raw;
}

void uart_tx(uint8_t c) {
    while (uart_status().s.status_tx_full != 0) {}
    *(volatile uint8_t *)(UART_REGS+UART_TXDATA_ADDR) = c;
}

uint8_t uart_rx(void) {
    // Only call this if we know there is something to read from the fifo
    uint8_t c = *(volatile uint8_t *)(UART_REGS+UART_RXDATA_ADDR);
    return c;
}

uart_status_t uart_status(void) {
    uart_status_t s;
    s.raw = UART_REGS[UART_STATUS_ADDR];
    return s;
}
