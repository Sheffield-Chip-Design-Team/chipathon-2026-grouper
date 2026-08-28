#include <stdint.h>
#include <stdbool.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "gpio.h"
#include "qspi.h"

#include "irq.h"


#define QSPI_PADS_MASK ( \
    (1u << GPIO_PIN_QSPI_SCK)   | \
    (1u << GPIO_PIN_QSPI_CE_N0) | \
    (1u << GPIO_PIN_QSPI_CE_N1) | \
    (1u << GPIO_PIN_QSPI_SIO0)  | \
    (1u << GPIO_PIN_QSPI_SIO1)  | \
    (1u << GPIO_PIN_QSPI_SIO2)  | \
    (1u << GPIO_PIN_QSPI_SIO3) )


int main(void) {
    set_irq_mask(0xfffffff8);
    debug_str("CPU Ready\n");
    init_uart();

    g_test_begin("qspi");

    // Hand GPIO pads 8-14 to the QSPI peripheral.
    gpio_set_altsel(QSPI_PADS_MASK);

    // Start in single-bit SPI mode, mode 0.
    qspi_config(
        1,      // CLKDIV
        false,  // single-bit SPI
        false   // mode 0
    );

    // APS6404L enter-QPI command.
    bool ok = qspi_command(
        0x35,   // opcode
        false,  // not a read
        false,  // no address
        0,
        false,  // no data
        0,      // no dummy cycles
        false,  // PSRAM
        0,
        10000
    );

    G_CHECK(ok);

    // Hardware should record successful PSRAM QPI initialisation.
    G_CHECK(qspi_status().s.init_done);

    // Switch the controller itself into quad mode.
    qspi_config(
        1,     // CLKDIV
        true,  // quad mode
        false  // mode 0
    );

    // Issue one known command/address/data transaction.
    //
    // The top-level Python test will observe this on the actual GPIO-facing
    // QSPI pads and check the values.
    uint8_t tx_data = 0xC3;

    ok = qspi_command(
        0xA5,       // arbitrary opcode
        false,      // write DATA phase
        true,       // address enabled
        0x123456,   // 24-bit address
        true,       // data enabled
        0,          // no dummy cycles
        false,      // PSRAM
        &tx_data,
        10000
    );

    G_CHECK(ok);

    qspi_status_t status = qspi_status();

    G_CHECK(status.s.done);
    G_CHECK(!status.s.busy);
    G_CHECK(!status.s.cfg_err);
    G_CHECK(!status.s.write_blocked);
    G_CHECK(!status.s.addr_err);

    puts("QSPI_TRANSACTION_DONE");

    return g_test_end();
}