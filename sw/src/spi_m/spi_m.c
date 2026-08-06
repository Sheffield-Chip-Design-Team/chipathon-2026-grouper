#include <stdint.h>
#include <stdbool.h>

#include "spi_m.h"

static volatile uint32_t *const SPI_M_REGS = (volatile uint32_t*) AHB_SPI_M_BASE;

void init_spi_m(void) {
    spi_m_ctrl_t x = {0};
    x.s.ctrl_enable = 1;
    SPI_M_REGS[SPI_M_CTRL_ADDR] = x.raw;
}

void spi_m_tx(uint8_t c) {
    while (spi_m_status().s.status_tx_ready == 0) {}
    *(volatile uint8_t *)(SPI_M_REGS + SPI_M_TXDATA_ADDR) = c;
}

uint8_t spi_m_rx(void) {
    return *(volatile uint8_t *)(SPI_M_REGS + SPI_M_RXDATA_ADDR);
}

spi_m_status_t spi_m_status(void) {
    spi_m_status_t s;
    s.raw = SPI_M_REGS[SPI_M_STATUS_ADDR];
    return s;
}
