#ifndef __QSPI_H__
#define __QSPI_H__

#include <stdint.h>
#include <stdbool.h>

#include "soc.h"
#include "greg.h"

// QSPI register addresses.
// Matches hw/rtl/qspi/ahb_qspi.sv.
#define QSPI_CTRL_ADDR    (AHB_QSPI_BASE + 0x00)
#define QSPI_CMD_ADDR     (AHB_QSPI_BASE + 0x04)
#define QSPI_STATUS_ADDR  (AHB_QSPI_BASE + 0x08)
#define QSPI_ADDR_ADDR    (AHB_QSPI_BASE + 0x0C)
#define QSPI_DATA_ADDR    (AHB_QSPI_BASE + 0x10)

// CTRL register.
typedef union {
    uint32_t raw;
    struct {
        uint32_t cpha           : 1;  // bit 0
        uint32_t cpol           : 1;  // bit 1
        uint32_t quad_mode      : 1;  // bit 2
        uint32_t flash_write_en : 1;  // bit 3
        uint32_t ie_done        : 1;  // bit 4
        uint32_t ie_err         : 1;  // bit 5
        uint32_t reserved0      : 2;  // bits 7:6
        uint32_t clkdiv         : 8;  // bits 15:8
        uint32_t reserved1      : 16; // bits 31:16
    } s;
} qspi_ctrl_t;

// CMD register.
//
// DIR applies only to the DATA phase:
//   0 = transmit data
//   1 = receive data
typedef union {
    uint32_t raw;
    struct {
        uint32_t start     : 1;  // bit 0
        uint32_t dir       : 1;  // bit 1
        uint32_t addr_en   : 1;  // bit 2
        uint32_t data_en   : 1;  // bit 3
        uint32_t target    : 1;  // bit 4: 0=PSRAM, 1=NOR
        uint32_t reserved0 : 3;  // bits 7:5
        uint32_t dummy     : 8;  // bits 15:8
        uint32_t opcode    : 8;  // bits 23:16
        uint32_t reserved1 : 8;  // bits 31:24
    } s;
} qspi_cmd_t;

// STATUS register.
typedef union {
    uint32_t raw;
    struct {
        uint32_t busy          : 1;  // bit 0
        uint32_t init_done     : 1;  // bit 1
        uint32_t done          : 1;  // bit 2
        uint32_t rx_valid      : 1;  // bit 3
        uint32_t cfg_err       : 1;  // bit 4
        uint32_t write_blocked : 1;  // bit 5
        uint32_t addr_err      : 1;  // bit 6
        uint32_t reserved      : 25;
    } s;
} qspi_status_t;

// Configure the static QSPI operating mode.
void qspi_config(uint8_t clkdiv, bool quad_mode, bool mode3);

// Read the current STATUS register.
qspi_status_t qspi_status(void);

// Execute one arbitrary QSPI command.
//
// data points to the byte to transmit when read=false.
// For a read, the received byte is written back through data.
//
// Returns false if the transaction does not complete before timeout_cycles.
bool qspi_command(
    uint8_t opcode,
    bool read,
    bool addr_en,
    uint32_t address,
    bool data_en,
    uint8_t dummy,
    bool target_nor,
    uint8_t *data,
    uint32_t timeout_cycles
);

#endif // __QSPI_H__