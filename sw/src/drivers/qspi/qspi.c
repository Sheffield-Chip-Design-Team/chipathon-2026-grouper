#include <stdint.h>
#include <stdbool.h>

#include "qspi.h"


void qspi_config(uint8_t clkdiv, bool quad_mode, bool mode3) {
    qspi_ctrl_t ctrl = {0};

    // The RTL supports SPI mode 0 and mode 3 only.
    if (mode3) {
        ctrl.s.cpol = 1;
        ctrl.s.cpha = 1;
    }

    ctrl.s.quad_mode = quad_mode ? 1 : 0;
    ctrl.s.clkdiv = clkdiv;

    g_wr32(QSPI_CTRL_ADDR, ctrl.raw);
}


qspi_status_t qspi_status(void) {
    qspi_status_t status;
    status.raw = g_rd32(QSPI_STATUS_ADDR);
    return status;
}


bool qspi_command(
    uint8_t opcode,
    bool read,
    bool addr_en,
    uint32_t address,
    bool data_en,
    uint8_t dummy,
    bool target_nor,
    uint32_t *data,
    uint32_t timeout_cycles
) {
    qspi_cmd_t cmd = {0};

    // Clear sticky completion/error status from any previous command.
    g_wr32(
        QSPI_STATUS_ADDR,
        (1u << 2) |  // DONE
        (1u << 3) |  // RX_VALID
        (1u << 4) |  // CFG_ERR
        (1u << 5) |  // WRITE_BLOCKED
        (1u << 6)    // ADDR_ERR
    );

    if (addr_en) g_wr32(QSPI_ADDR_ADDR, address & 0x00FFFFFFu);
    if (data_en && !read && data != 0) g_wr32(QSPI_DATA_ADDR, *data);

    cmd.s.start = 1;
    cmd.s.dir = read ? 1 : 0;
    cmd.s.addr_en = addr_en ? 1 : 0;
    cmd.s.data_en = data_en ? 1 : 0;
    cmd.s.target = target_nor ? 1 : 0;
    cmd.s.dummy = dummy;
    cmd.s.opcode = opcode;

    g_wr32(QSPI_CMD_ADDR, cmd.raw);

    // Wait for the transaction to complete.
    if (!g_poll(QSPI_STATUS_ADDR, (1u << 2), (1u << 2), timeout_cycles)) return false;

    // Return received data to the caller.
    if (data_en && read && data != 0) *data = g_rd32(QSPI_DATA_ADDR);

    return true;
}
