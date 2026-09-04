#pragma once

#ifdef _MSC_VER
// Silence IDE warnings about __attribute__ when C/C++ style set to MSVC
#define __attribute__(x)
#endif

#include <stdint.h>
#include <stdbool.h>
#include "config.h"

// The baud is compiled in: sw/scripts/build_bootloader.sh passes
// -DUART_BAUD_RATE=$BAUD and publishes the same value as uart_baud.txt, which
// the testbench reads to drive the other end of the link. There is
// deliberately no default here - a fallback that disagreed with what the
// script advertised would produce a link that fails to decode while both
// sides believed they agreed.
#ifndef UART_BAUD_RATE
#error "UART_BAUD_RATE is not defined - build via sw/scripts/build_bootloader.sh"
#endif

#define BAUD_RATE UART_BAUD_RATE

static volatile uint32_t *const UART_REGS = (volatile uint32_t*) AHB_UART_BASE; 

#define UART_CTRL_ADDR   0
#define UART_STATUS_ADDR 1
#define UART_TXDATA_ADDR 2
#define UART_RXDATA_ADDR 3

typedef union {
    struct __attribute__((packed)) {
        unsigned int ctrl_enable: 1;
        unsigned int ctrl_tx_en: 1;
        unsigned int ctrl_rx_en: 1;
        unsigned int ctrl_rx_resync_en: 1;
        unsigned int ctrl_tx_break: 1;
        unsigned int ctrl_flush_tx_fifo: 1;
        unsigned int ctrl_flush_rx_fifo: 1;
        int _rsvd1: 9;
        unsigned int ctrl_clk_div: 10;
        int _rsvd2: 6;
    } s;
    uint32_t raw;
} uart_ctrl_t;

typedef union {
    struct __attribute__((packed)) {
        unsigned int status_tx_empty: 1;
        unsigned int status_tx_full: 1;
        unsigned int status_rx_empty: 1;
        unsigned int status_rx_full: 1;
        unsigned int status_tx_active: 1;
        unsigned int status_rx_frame_error: 1;
        unsigned int status_rx_break: 1;
        int _rsvd: 25;
    } s;
    uint32_t raw;
} uart_status_t;

// -1 as register value is offset, e.g. 1 is a divide by 2
// +0.5 to round to nearest integer
// *8 as we have 8x oversampling
//
// The (double) cast is load bearing and must match the expression in
// sw/src/drivers/uart/uart.c exactly - the bootloader and the firmware it
// loads have to agree on the divisor. Without it SYS_CLK_HZ/(BAUD_RATE*8)
// truncates before the -0.5, which rounds the wrong way and yields a divisor
// one too small at 38400, 57600 and 115200 (a 10% baud error at 115200).
static const int clk_div = (double)SYS_CLK_HZ/((BAUD_RATE)*8) - 0.5;

static inline void init_uart(void) {
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

static inline uart_status_t uart_status(void) {
    uart_status_t s;
    s.raw = UART_REGS[UART_STATUS_ADDR];
    return s;
}

static inline uint8_t uart_blocking_rx(void) {
    while (uart_status().s.status_rx_empty != 0) {}
    // Only call this if we know there is something to read from the fifo
    uint8_t c = *(volatile uint8_t *)(UART_REGS+UART_RXDATA_ADDR);
    return c;
}

static inline void uart_tx(uint8_t c) {
    while (uart_status().s.status_tx_full != 0) {}
    *(volatile uint8_t *)(UART_REGS+UART_TXDATA_ADDR) = c;
}
