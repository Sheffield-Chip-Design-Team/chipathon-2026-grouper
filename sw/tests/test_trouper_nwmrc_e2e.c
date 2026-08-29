#include <stdint.h>
#include "config.h"
#include "irq.h"

/* Run the production RV32EMC NW-MRC implementation through Grouper's real
 * native IRQ path. Foreground owns quiet-window polling; the IRQ owns the
 * packet-critical TRAINING_DONE -> W_COMMIT path. */
#define ASIC_REG_BASE AHB_EXT_BASE
#define main trouper_foreground_main
#include "../../../trouper/firmware/picorv32/main.c"
#undef main

#define RESULT_WORD (*(volatile uint32_t *)0x00000FF0u)
#define RESULT_PASS 0x4E574D52u
#define RESULT_FAIL 0xBAD00000u
#define REG_SC_FORCE_LOCK 0x19u
static volatile uint8_t noise_seen, packet_seen;

void grouper_external_irq(uint32_t irqs)
{
    uint8_t status;
    if (!(irqs & IRQ_TROUPER)) return;
    status = reg_read8(REG_IRQ_STATUS);
    if (status & IRQ_NOISE_READY) {
        update_noise_floor_fw();
        noise_seen = 1u;
        reg_write8(REG_SC_FORCE_LOCK, 1u);
    } else if ((status & IRQ_TRAINING_DONE) && noise_seen && !packet_seen) {
        handle_training_done();
        packet_seen = 1u;
    }
    reg_write8(REG_IRQ_CLEAR, status);
}

int main(void)
{
    unsigned int timeout;
    RESULT_WORD = 0xC0DE4E00u;
    set_irq_mask(irq_mask & ~IRQ_TROUPER);
    asic_cfg_commit();
    reg_write8(REG_TACC_NOISE_TRIG, 1u);
    for (timeout = 0; timeout < 600000u && !packet_seen; ++timeout) { }
    RESULT_WORD = (!noise_seen || !packet_seen || !nfe_valid() ||
                   !(reg_read8(REG_PACKET_STATUS) & PACKET_STATUS_W_VALID_BIT))
        ? RESULT_FAIL : RESULT_PASS;
    for (;;) { }
}
