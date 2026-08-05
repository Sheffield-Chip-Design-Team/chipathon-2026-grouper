#define IRQ_IMPL // Don't mark as const for this file
#include "irq.h"
#undef IRQ_IMPL

#include "uart.h"
#include "debug.h"

// Include custom IRQ instructions
#include "./custom_ops.h"

uint32_t irq_mask = INIT_IRQS_MASK;

uint32_t set_irq_mask(uint32_t new_mask) {
	uint32_t old_mask = 0;
	picorv32_maskirq_insn(old_mask, new_mask);
	irq_mask = new_mask;
	return old_mask;
}

uint32_t *irq(uint32_t *regs, uint32_t irqs) {
#ifdef DEBUG_IRQ
	debug(0xfe, irqs);
#endif

	// checking compressed isa q0 reg handling
	if ((irqs & (IRQ_EBREAK | IRQ_BUS_ERR)) == 0) {
		if ((irqs & IRQ_TIMER) != 0) {
			debug_str("[TIMER-IRQ]");
		}
		
		if ((irqs & IRQ_UART_RX) != 0) {
			debug_str("[UART-RX-IRQ] ");
			while (uart_status().s.status_rx_empty == 0) {
				uint8_t c = uart_rx();
				debug_char(c);
			}
			debug_char('\n');
		}

		if ((irqs & IRQ_UART_RX_ERR) != 0) {
			debug_str("[UART-RX-ERR-IRQ]");
			if (uart_status().s.status_rx_break != 0) {
				// Stop the simulation
				debug(0xff, 0xDEAD600D);
			}
		}
	}

	// Check we don't still have a system error interrupt
	if ((irqs & (IRQ_EBREAK | IRQ_BUS_ERR)) != 0)
	{
		uint32_t pc = (regs[0] & 1) ? regs[0] - 3 : regs[0] - 4;
		uint32_t instr = *(uint16_t*)pc;

		if ((instr & 3) == 3)
			instr = instr | (*(uint16_t*)(pc + 2)) << 16;

		if ((irqs & 2) != 0) debug_str("Error: EBREAK/ECALL/Illegal Instruction IRQ Fired\n");
		if ((irqs & 4) != 0) debug_str("Error: Bus Error IRQ Fired\n");
		debug(0xff, pc); // Debug the instruction that caused the bus error

		__asm__ volatile ("ebreak");
	}

	return regs;
}

