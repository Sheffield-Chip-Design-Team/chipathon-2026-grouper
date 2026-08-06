#ifndef __SPI_M_H__
#define __SPI_M_H__

#include <stdint.h>
#include <stdbool.h>

// NOTE: hw/rtl/spi_m/ does not exist yet. 0x00006000-0x00006fff is routed
// through ahb_stub_slave (hw/rtl/interconnect/ahb_stub_slave.sv), which
// returns an AHB error response on every access. This driver mirrors
// uart/uart.h's shape as a placeholder/template only - the bitfields
// below are NOT derived from real RTL (none exists) and must be revisited
// once real SPI Master RTL lands. Do not call these functions from
// firmware yet: doing so will raise IRQ_BUS_ERR.
//
// AHB_SPI_M_BASE lives in soc.h with the rest of the address map.
#include "soc.h"

#define SPI_M_CTRL_ADDR   0
#define SPI_M_STATUS_ADDR 1
#define SPI_M_TXDATA_ADDR 2
#define SPI_M_RXDATA_ADDR 3

typedef union {
    uint32_t raw;
    struct { uint32_t ctrl_enable : 1; uint32_t reserved : 31; } s;
} spi_m_ctrl_t;

typedef union {
    uint32_t raw;
    struct { uint32_t status_tx_ready : 1; uint32_t reserved : 31; } s;
} spi_m_status_t;

void init_spi_m(void);
void spi_m_tx(uint8_t c);
uint8_t spi_m_rx(void);
spi_m_status_t spi_m_status(void);

#endif // __SPI_M_H__
