#ifndef __SPI_M_H__
#define __SPI_M_H__

#include <stdint.h>
#include <stdbool.h>

// AHB SPI master driver.
//
// Matches the register map in hw/rtl/spi_m/ahb_spi_m.sv. The block drives an
// external APS6404L-compatible SPI PSRAM (GRPR-SPIM-004), so the opcodes
// below are the SPI-mode subset of that datasheet's command table.
//
// AHB_SPI_M_BASE lives in config.h with the rest of the address map.
#include "config.h"
#include "greg.h"

#define SPI_M_CTRL_ADDR       (AHB_SPI_M_BASE + 0x00)
#define SPI_M_CMD_ADDR        (AHB_SPI_M_BASE + 0x04)
#define SPI_M_STATUS_ADDR     (AHB_SPI_M_BASE + 0x08)
#define SPI_M_IRQ_STATUS_ADDR (AHB_SPI_M_BASE + 0x0C)
#define SPI_M_IRQ_EN_ADDR     (AHB_SPI_M_BASE + 0x10)
#define SPI_M_ADDR_ADDR       (AHB_SPI_M_BASE + 0x14)
#define SPI_M_DATA_ADDR       (AHB_SPI_M_BASE + 0x18)

// CTRL - 0x00. CPOL and CPHA must be written equal: only modes 0 and 3 are
// supported, and an unequal pair is rejected with an AHB error response
// (GRPR-SPIM-016).
typedef union {
    uint32_t raw;
    struct {
        uint32_t cpha        : 1;   // bit 0
        uint32_t cpol        : 1;   // bit 1
        uint32_t reserved0   : 1;   // bit 2
        uint32_t enable      : 1;   // bit 3
        uint32_t reserved1   : 4;   // bits 7:4
        uint32_t clkdiv      : 8;   // bits 15:8  SCLK = fclk / (2*(CLKDIV+1))
        uint32_t ie_complete : 1;   // bit 16
        uint32_t ie_err      : 1;   // bit 17
        uint32_t reserved2   : 14;  // bits 31:18
    } s;
} spi_m_ctrl_t;

// CMD - 0x04. Written with START=1 to launch a transfer.
// Phase order is CMD -> ADDR -> DUMMY -> DATA; any phase may be omitted.
typedef union {
    uint32_t raw;
    struct {
        uint32_t start      : 1;   // bit 0      self-clearing
        uint32_t opcode     : 8;   // bits 8:1
        uint32_t cmd_en     : 1;   // bit 9
        uint32_t addr_en    : 1;   // bit 10
        uint32_t addr_bytes : 2;   // bits 12:11 0=1 byte .. 3=4 bytes
        uint32_t data_en    : 1;   // bit 13
        uint32_t dir        : 1;   // bit 14     0=write, 1=read
        uint32_t dummy      : 5;   // bits 19:15
        uint32_t data_len   : 8;   // bits 27:20 bytes minus 1
        uint32_t rx_flush   : 1;   // bit 28
        uint32_t tx_flush   : 1;   // bit 29
        uint32_t reserved   : 2;   // bits 31:30
    } s;
} spi_m_cmd_t;

// STATUS - 0x08 (read-only).
typedef union {
    uint32_t raw;
    struct {
        uint32_t busy     : 1;   // bit 0
        uint32_t tx_empty : 1;   // bit 1
        uint32_t tx_full  : 1;   // bit 2
        uint32_t rx_empty : 1;   // bit 3
        uint32_t rx_full  : 1;   // bit 4
        uint32_t reserved : 27;  // bits 31:5
    } s;
} spi_m_status_t;

// IRQ_STATUS - 0x0C (write-1-to-clear). IRQ_EN uses the same bit positions.
//
// UNDERRUN/OVERRUN are the in-transfer (wire-side) FIFO events;
// UNDERFLOW and OVERFLOW are the AHB access errors - reading DATA with the RX FIFO empty and
// writing DATA with the TX FIFO full. They are separate bits (SPIM-SPEC-001).
#define SPI_M_IRQ_TXN_COMPLETE (1u << 0)
#define SPI_M_IRQ_UNDERRUN     (1u << 1)
#define SPI_M_IRQ_OVERRUN      (1u << 2)
#define SPI_M_IRQ_CFG_ERR      (1u << 3)
#define SPI_M_IRQ_UNDERFLOW    (1u << 4)
#define SPI_M_IRQ_OVERFLOW     (1u << 5)

#define SPI_M_IRQ_ALL ( \
    SPI_M_IRQ_TXN_COMPLETE | SPI_M_IRQ_UNDERRUN | SPI_M_IRQ_OVERRUN | \
    SPI_M_IRQ_CFG_ERR | SPI_M_IRQ_UNDERFLOW | SPI_M_IRQ_OVERFLOW)

// ADDR_BYTES encoding for CMD.addr_bytes.
#define SPI_M_ADDR_1B 0
#define SPI_M_ADDR_2B 1
#define SPI_M_ADDR_3B 2
#define SPI_M_ADDR_4B 3

// APS6404L SPI-mode opcodes (datasheet rev 2.3 section 8.5).
#define APS_OP_READ         0x03  // 24-bit address, 0 wait cycles
#define APS_OP_FAST_READ    0x0B  // 24-bit address, 8 wait cycles
#define APS_OP_WRITE        0x02  // 24-bit address, 0 wait cycles
#define APS_OP_READ_ID      0x9F  // 24-bit address, 0 wait cycles
#define APS_OP_RESET_EN     0x66  // no address, no data
#define APS_OP_RESET        0x99  // no address, no data
#define APS_OP_ENTER_QPI    0x35  // no address, no data
#define APS_OP_WRAP_TOGGLE  0xC0  // no address, no data

// Wait cycles the APS6404L needs between address and data on a Fast Read.
#define APS_FAST_READ_DUMMY 8

// Bring the block up in the given mode. `mode` is 0 or 3; anything else is
// rejected by the hardware, so this clamps to 0.
void spi_m_init(uint8_t clkdiv, uint8_t mode);

// Raw register views.
spi_m_status_t spi_m_status(void);
uint32_t spi_m_irq_status(void);
void spi_m_clear_irq(uint32_t mask);

// Issue a command-only transaction (no address, no data) - the shape the
// APS6404L's Reset Enable / Reset / Enter QPI commands take.
bool spi_m_cmd_only(uint8_t opcode, uint32_t timeout_cycles);

// Write `len` bytes to `address` on the device. len must be 1..256 and no
// larger than what the caller can keep the TX FIFO fed with; the block stalls
// SCK with CS# still low if the FIFO runs dry, so this pushes as it goes.
bool spi_m_write(uint8_t opcode, uint32_t address, const uint8_t *data,
                 uint32_t len, uint32_t timeout_cycles);

// Read `len` bytes from `address`. `dummy` is the wait-cycle count the opcode
// requires - 0 for APS_OP_READ, APS_FAST_READ_DUMMY for APS_OP_FAST_READ.
bool spi_m_read(uint8_t opcode, uint32_t address, uint8_t *data,
                uint32_t len, uint8_t dummy, uint32_t timeout_cycles);

#endif // __SPI_M_H__
