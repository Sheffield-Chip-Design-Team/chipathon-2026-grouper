#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "boot_uart.h"

#define BANK_SWITCH_ADDR 0x7ffffffc

static inline void boot_from_ram(void) {
    *((volatile uint32_t*) BANK_SWITCH_ADDR) = 1; // Swap ROM and RAM, and boot from RAM
    while (1) {}
}

static inline uint32_t rx_uint(void) {
    uint32_t x = 0;
    for (int i = 0; i < 4; i++) {
        x <<= 8;
        x |= uart_blocking_rx();
    }
    return x;
}

static inline void tx_uint(uint32_t x) {
    for (int i = 0; i < 4; i++) {
        uart_tx((x >> 24) & 0xff);
        x <<= 8;
    }
}

// The stack usage can be decreased to 0, by marking the function as "naked",
// this means the function doesn't do any register preservation, etc. (or any other compiler prologue/epilogue code)
// This may break things, so should only really be used on non-returning functions
__attribute__ ((naked)) void main(void) {
    uint32_t addr;
    uint32_t len;
    uint32_t value;

    init_uart();

    uart_tx('h');
    uart_tx('i');
    uart_tx('\n');

    while (1) {
        uint8_t c = uart_blocking_rx();
        switch (c) {
            case '\n':
                uart_tx('\n');
                break;
            case 'R': // Read
                addr = rx_uint();
                len = rx_uint();
                while (len--) {
                    value = *((volatile uint32_t*) addr);
                    tx_uint(value);
                    addr += 4;
                }
                break;
            case 'W': // Write
                addr = rx_uint();
                len = rx_uint();
                while (len--) {
                    value = rx_uint();
                    *((volatile uint32_t*) addr) = value;
                    addr += 4;
                }
                break;
            case 'B': // Reboot to RAM
                boot_from_ram();
        }
    }
}
