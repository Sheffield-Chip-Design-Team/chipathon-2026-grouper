#include <stdint.h>
#include <stdbool.h>

#include "spi_m.h"

// Only modes 0 and 3 exist, and the hardware raises CFG_ERR (and an AHB error
// response) on an unequal CPOL/CPHA pair - GRPR-SPIM-016. Mode n means both
// bits equal, so this collapses to "mode 3 or mode 0".
void spi_m_init(uint8_t clkdiv, uint8_t mode) {
    spi_m_ctrl_t ctrl = {0};
    uint32_t bit = (mode == 3) ? 1u : 0u;

    ctrl.s.cpha   = bit;
    ctrl.s.cpol   = bit;
    ctrl.s.enable = 1;
    ctrl.s.clkdiv = clkdiv;

    g_wr32(SPI_M_CTRL_ADDR, ctrl.raw);

    // Start from a known state: drop anything a previous run left in the
    // FIFOs and clear the sticky event bits.
    spi_m_cmd_t flush = {0};
    flush.s.rx_flush = 1;
    flush.s.tx_flush = 1;
    g_wr32(SPI_M_CMD_ADDR, flush.raw);

    g_wr32(SPI_M_IRQ_STATUS_ADDR, SPI_M_IRQ_ALL);
}

spi_m_status_t spi_m_status(void) {
    spi_m_status_t s;
    s.raw = g_rd32(SPI_M_STATUS_ADDR);
    return s;
}

uint32_t spi_m_irq_status(void) {
    return g_rd32(SPI_M_IRQ_STATUS_ADDR);
}

void spi_m_clear_irq(uint32_t mask) {
    g_wr32(SPI_M_IRQ_STATUS_ADDR, mask);
}

// Wait for TXN_COMPLETE. BUSY alone is not enough: it drops at the end of the
// wire activity, while TXN_COMPLETE is the latched "this transfer finished"
// event the spec gives firmware (GRPR-SPIM-008).
static bool wait_done(uint32_t timeout_cycles) {
    return g_poll(SPI_M_IRQ_STATUS_ADDR,
                  SPI_M_IRQ_TXN_COMPLETE,
                  SPI_M_IRQ_TXN_COMPLETE,
                  timeout_cycles);
}

bool spi_m_cmd_only(uint8_t opcode, uint32_t timeout_cycles) {
    spi_m_clear_irq(SPI_M_IRQ_ALL);

    spi_m_cmd_t cmd = {0};
    cmd.s.start  = 1;
    cmd.s.opcode = opcode;
    cmd.s.cmd_en = 1;
    // No address, no data - CMD phase only.

    g_wr32(SPI_M_CMD_ADDR, cmd.raw);
    return wait_done(timeout_cycles);
}

bool spi_m_write(uint8_t opcode, uint32_t address, const uint8_t *data,
                 uint32_t len, uint32_t timeout_cycles) {
    if (len == 0 || len > 256) return false;

    spi_m_clear_irq(SPI_M_IRQ_ALL);
    g_wr32(SPI_M_ADDR_ADDR, address & 0x00FFFFFFu);

    // Prime the TX FIFO before START so the data phase has bytes waiting.
    // FIFO_DEPTH is 4, so anything longer is fed below as the block drains
    // it - a DATA_LEN larger than the FIFO is the normal case, not an error.
    uint32_t pushed = 0;
    while (pushed < len && !(g_rd32(SPI_M_STATUS_ADDR) & (1u << 2))) {
        g_wr8(SPI_M_DATA_ADDR, data[pushed]);
        pushed++;
    }

    spi_m_cmd_t cmd = {0};
    cmd.s.start      = 1;
    cmd.s.opcode     = opcode;
    cmd.s.cmd_en     = 1;
    cmd.s.addr_en    = 1;
    cmd.s.addr_bytes = SPI_M_ADDR_3B;   // APS6404L takes a 24-bit address
    cmd.s.data_en    = 1;
    cmd.s.dir        = 0;               // write: drain the TX FIFO
    cmd.s.data_len   = (len - 1) & 0xFF;

    g_wr32(SPI_M_CMD_ADDR, cmd.raw);

    // Keep feeding. If the FIFO runs dry mid-transfer the block stalls SCK
    // with CS# still asserted and sets UNDERRUN, then resumes on the next
    // push - so a slow feeder costs cycles, not correctness.
    while (pushed < len) {
        if (!g_poll(SPI_M_STATUS_ADDR, (1u << 2), 0, timeout_cycles)) {
            return false;
        }
        g_wr8(SPI_M_DATA_ADDR, data[pushed]);
        pushed++;
    }

    return wait_done(timeout_cycles);
}

bool spi_m_read(uint8_t opcode, uint32_t address, uint8_t *data,
                uint32_t len, uint8_t dummy, uint32_t timeout_cycles) {
    if (len == 0 || len > 256) return false;

    spi_m_clear_irq(SPI_M_IRQ_ALL);
    g_wr32(SPI_M_ADDR_ADDR, address & 0x00FFFFFFu);

    // Drop anything stale so the first pop below is this transfer's byte 0.
    spi_m_cmd_t flush = {0};
    flush.s.rx_flush = 1;
    g_wr32(SPI_M_CMD_ADDR, flush.raw);

    spi_m_cmd_t cmd = {0};
    cmd.s.start      = 1;
    cmd.s.opcode     = opcode;
    cmd.s.cmd_en     = 1;
    cmd.s.addr_en    = 1;
    cmd.s.addr_bytes = SPI_M_ADDR_3B;
    cmd.s.data_en    = 1;
    cmd.s.dir        = 1;               // read: fill the RX FIFO
    cmd.s.dummy      = dummy & 0x1F;
    cmd.s.data_len   = (len - 1) & 0xFF;

    g_wr32(SPI_M_CMD_ADDR, cmd.raw);

    // Drain as it fills. The RX FIFO is only FIFO_DEPTH deep, so a read
    // longer than that has to be popped during the transfer or it overruns.
    // Popping an empty FIFO would return a stale byte and set UNDERRUN, so
    // each pop waits for RX_EMPTY to clear - with the same timeout as the
    // transfer, so a device that never answers fails instead of hanging.
    for (uint32_t popped = 0; popped < len; popped++) {
        if (!g_poll(SPI_M_STATUS_ADDR, (1u << 3), 0, timeout_cycles)) {
            return false;
        }
        data[popped] = (uint8_t) g_rd32(SPI_M_DATA_ADDR);
    }

    return wait_done(timeout_cycles);
}
