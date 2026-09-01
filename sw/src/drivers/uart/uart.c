#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "uart.h"
#include "debug.h"
// AHB_UART_BASE and SYS_CLK_HZ live in config.h - they describe the SoC, not
// this driver, and gtime.h needs the clock too.

// Baud rate init_uart() configures. Overridable from the build so a
// simulation can run the link far faster than the silicon default - see
// --baud/FW_BAUD in sw/scripts/build_fw.sh and build_bootloader.sh. Anything
// driving the other end of the link has to be told the same value; the build
// scripts publish it as uart_baud.txt next to the ROM image.
#ifndef UART_BAUD_RATE
#define UART_BAUD_RATE 19200
#endif

// AHB_UART_BASE and the UART_*_ADDR register offsets now live in uart.h.

static volatile uint32_t *const UART_REGS = (volatile uint32_t*) AHB_UART_BASE;

// Baud divisor for the CTRL register's clk_div field.
//
// uart_clk_div.sv reloads its counter with clk_div and counts down to zero, so
// a baud tick is clk_div + 1 clocks, and uart.sv oversamples by 8. That makes
// the true relationship
//
//   baud = SYS_CLK_HZ / ((clk_div + 1) * 8)   ->   clk_div = round(SYS_CLK_HZ / (baud * 8)) - 1
//
// The -0.5 is that round()-then-subtract-one done in integer truncation. The
// DV layer computes the same thing in clk_div_for_baud() in
// hw/dv/ahb_uart/uart_clk_math.py - the two have to agree, and the block-level
// UART tests drive the RTL from that one.
//
// The off-by-one matters more the faster the link runs: at 19200 dropping the
// -1 is a 1.4% baud error that mid-bit sampling absorbs, but at 625000 it is
// 33% and nothing decodes.
static const int clk_div = (double)SYS_CLK_HZ/(UART_BAUD_RATE*8) - 0.5;

// Initialise the UART to a known state, and set the baud rate divisor. 
void init_uart(void) {
    uart_ctrl_t x      = {0};
    x.s.ctrl_enable    = 1;
    x.s.ctrl_tx_en     = 1;
    x.s.ctrl_clk_div   = clk_div;
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

// Spin until the RX FIFO has a byte, then take it. This is the safe way to
// read: ahb_uart.sv raises a bus error on a read of an empty RX FIFO, which
// reaches the CPU as IRQ_BUS_ERR, so uart_rx() on its own is only correct once
// something else has checked uart_status().
uint8_t uart_blocking_rx(void) {
    while (uart_status().s.status_rx_empty != 0) {}
    return uart_rx();
}

uart_status_t uart_status(void) {
    uart_status_t s;
    s.raw = UART_REGS[UART_STATUS_ADDR];
    return s;
}
