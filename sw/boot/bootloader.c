// GrouperSoC ROM bootloader.
//
// Out of reset bank_switch is 0, so this runs from ROM at 0x0000_0000 and RAM
// answers at 0x4000_0000. It accepts commands on the UART, and 'B' writes the
// bank switch - which swaps RAM to zero and resets the CPU, so the CPU
// re-fetches its reset vector from the image just received. Link that image
// with sw/boot/ram.ld (build_fw.sh --link ram).
//
// Wire protocol, all multi-byte values big-endian so a host can send them
// straight from a hex string:
//
//   '\n'                        echoed back, a liveness check
//   'R' <addr:4> <len:4>        read len words from addr, each echoed back
//   'W' <addr:4> <len:4> <w>... write len words to addr
//   'B'                         swap the banks and reboot into RAM
//
// Note that addresses are the ones the *bootloader* sees, i.e. RAM is at
// RAM_BASE (0x4000_0000), not at the zero it will appear at after 'B'.
//
// Built by sw/scripts/build_bootloader.sh, which is also where the ROM budget
// and the zero-stack rule below are enforced.
//
//
// Zero stack usage
// ----------------
// The bootloader writes the image it receives from the bottom of RAM up, and
// the stack would grow down from _estack at the top of the same 4 KiB. There
// is no guard between them and nothing at run time notices them meeting, so
// instead of budgeting headroom the bootloader uses no stack at all - an image
// may then fill RAM to the last word.
//
// Three things together get main()'s frame to zero, and all three matter:
//
//   1. main() must be a leaf. A call forces GCC to spill ra. That is why the
//      UART accessors below are local always_inline copies of the ones in
//      sw/src/drivers/uart/uart.c rather than calls into it, and why uart.c is
//      not in build_bootloader.sh's SOURCES. Plain `static inline` is not
//      enough: at -Os GCC outlined rx_uint() because it had two call sites.
//   2. No callee-saved register may be live. RV32E has exactly two (s0/s1),
//      and if the allocator picks one it emits a prologue to save it.
//      build_bootloader.sh passes -ffixed-s0 -ffixed-s1 to take them off the
//      table; ra, t0-t2 and a0-a5 are plenty for this code.
//   3. Nothing may need spilling. That is the residual risk, and it is what
//      the -fstack-usage check in build_bootloader.sh (budget 0) proves.
//
// Note that main() is deliberately *not* __attribute__((naked)). Once the
// frame is zero, naked buys nothing; and if the frame ever stops being zero,
// naked turns a caught build failure into a silent store past _estack, because
// a naked function has no prologue in which to move sp. Let the compiler emit
// the frame it thinks it needs, and fail the build if it emits one at all.

#include <stdint.h>
#include <stdbool.h>

#include "config.h"
// For uart_ctrl_t / uart_status_t and the UART_*_ADDR register offsets. The
// function declarations in there are unused - see the boot_uart_* copies
// below - and uart.c is not linked in.
#include "uart.h"

#define ALWAYS_INLINE static inline __attribute__((always_inline))

#define UART_REGS ((volatile uint32_t*) AHB_UART_BASE)

// Baud divisor, same expression as clk_div in sw/src/drivers/uart/uart.c:
// uart_clk_div.sv counts clk_div + 1 clocks per tick and uart.sv oversamples
// by 8, so clk_div = round(SYS_CLK_HZ / (baud * 8)) - 1. A macro rather than
// uart.c's `static const int` so it folds to an immediate and leaves no
// .rodata object behind.
#define UART_CLK_DIV ((uint32_t) ((double) SYS_CLK_HZ / (UART_BAUD_RATE * 8) - 0.5))

ALWAYS_INLINE uart_status_t boot_uart_status(void) {
    uart_status_t s;
    s.raw = UART_REGS[UART_STATUS_ADDR];
    return s;
}

ALWAYS_INLINE void boot_uart_init(void) {
    uart_ctrl_t x          = {0};
    x.s.ctrl_enable        = 1;
    x.s.ctrl_tx_en         = 1;
    x.s.ctrl_rx_en         = 1;
    x.s.ctrl_rx_resync_en  = 1;
    x.s.ctrl_flush_tx_fifo = 1;
    x.s.ctrl_flush_rx_fifo = 1;
    x.s.ctrl_clk_div       = UART_CLK_DIV;
    UART_REGS[UART_CTRL_ADDR] = x.raw;
}

ALWAYS_INLINE void boot_uart_tx(uint8_t c) {
    while (boot_uart_status().s.status_tx_full != 0) {}
    *(volatile uint8_t*) (UART_REGS + UART_TXDATA_ADDR) = c;
}

// ahb_uart.sv raises a bus error on a read of an empty RX FIFO, which reaches
// the CPU as IRQ_BUS_ERR, so the status poll is not optional.
ALWAYS_INLINE uint8_t boot_uart_rx(void) {
    while (boot_uart_status().s.status_rx_empty != 0) {}
    return *(volatile uint8_t*) (UART_REGS + UART_RXDATA_ADDR);
}

ALWAYS_INLINE void boot_from_ram(void) {
    // Swap ROM and RAM, and boot from RAM. cpu_ss holds the CPU in reset for
    // the cycle it takes the write, so this never returns.
    *((volatile uint32_t*) BANK_SWITCH_ADDR) = 1;
    while (1) {}
}

ALWAYS_INLINE uint32_t rx_uint(void) {
    uint32_t x = 0;
    for (int i = 0; i < 4; i++) {
        x <<= 8;
        x |= boot_uart_rx();
    }
    return x;
}

ALWAYS_INLINE void tx_uint(uint32_t x) {
    for (int i = 0; i < 4; i++) {
        boot_uart_tx((x >> 24) & 0xff);
        x <<= 8;
    }
}

void main(void) {
    uint32_t addr;
    uint32_t len;
    uint32_t value;

    boot_uart_init();

    boot_uart_tx('h');
    boot_uart_tx('i');
    boot_uart_tx('\n');

    while (1) {
        uint8_t c = boot_uart_rx();
        switch (c) {
            case '\n':
                boot_uart_tx('\n');
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
