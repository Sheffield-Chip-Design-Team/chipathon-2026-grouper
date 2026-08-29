#include <stdint.h>
#include <stdbool.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "gpio.h"
#include "spi_m.h"

#include "irq.h"

// Pads 4-7 carry the SPI master's alternate function (hw/rtl/io_ss.sv). The
// testbench hangs an APS6404L model (hw/tb/models/aps6404l.py) off them.
#define SPI_M_PADS_MASK ( \
    (1u << GPIO_PIN_SPI_M_SS)   | \
    (1u << GPIO_PIN_SPI_M_SCK)  | \
    (1u << GPIO_PIN_SPI_M_MOSI) | \
    (1u << GPIO_PIN_SPI_M_MISO) )

#define TIMEOUT 20000

// Small enough to fit the 4-entry FIFOs without relying on the stall path,
// which the block-level TB covers separately.
#define PAYLOAD_LEN 4
#define PSRAM_ADDR  0x012345u

int main(void) {
    set_irq_mask(0xfffffff8);
    debug_str("CPU Ready\n");
    init_uart();

    g_test_begin("spi_m");

    // Hand pads 4-7 to the SPI master, and turn the MISO pad's input buffer
    // on - io_ss routes the pad through, but GPIO_IE still gates it.
    gpio_set_ie(1u << GPIO_PIN_SPI_M_MISO);
    gpio_set_altsel(SPI_M_PADS_MASK);

    // CLKDIV=1 gives the 4 MHz default SCK of GRPR-SPIM-013, mode 0.
    spi_m_init(1, 0);

    // The APS6404L powers up in SPI mode and wants CE# high before anything
    // else (datasheet 8.4), which reset already gives us. Reset Enable then
    // Reset is the datasheet's init pair - both are command-only.
    G_CHECK(spi_m_cmd_only(APS_OP_RESET_EN, TIMEOUT));
    G_CHECK(spi_m_cmd_only(APS_OP_RESET, TIMEOUT));

    // Write a known payload, then read it back through the device model.
    static const uint8_t tx[PAYLOAD_LEN] = { 0xDE, 0xAD, 0xBE, 0xEF };
    uint8_t rx[PAYLOAD_LEN] = { 0 };

    G_CHECK(spi_m_write(APS_OP_WRITE, PSRAM_ADDR, tx, PAYLOAD_LEN, TIMEOUT));
    G_CHECK(spi_m_read(APS_OP_READ, PSRAM_ADDR, rx, PAYLOAD_LEN, 0, TIMEOUT));

    // Checked in pairs rather than per byte: each G_CHECK costs ~75 bytes of
    // image for the stringified expression, and this test sits against the
    // 4 KiB RAM ceiling. The testbench's device model shows the full payload
    // either way.
    G_CHECK_EQ(rx[0], tx[0]);
    G_CHECK_EQ(rx[3], tx[3]);

    // Fast Read returns the same bytes, but needs the 8 wait cycles the
    // datasheet's section 8.5 table gives 'h0B. Reuse rx rather than adding
    // a second buffer - the RAM image has no room to spare.
    G_CHECK(spi_m_read(APS_OP_FAST_READ, PSRAM_ADDR, rx, PAYLOAD_LEN,
                       APS_FAST_READ_DUMMY, TIMEOUT));
    G_CHECK_EQ(rx[0], tx[0]);
    G_CHECK_EQ(rx[3], tx[3]);

    // Nothing should have gone wrong on the way.
    G_CHECK_EQ(spi_m_irq_status() & (SPI_M_IRQ_UNDERRUN | SPI_M_IRQ_OVERRUN |
                                     SPI_M_IRQ_CFG_ERR), 0);

    puts("SPI_M_TRANSACTION_DONE");

    return g_test_end();
}
