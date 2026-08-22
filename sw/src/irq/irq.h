#ifndef __IRQ_H__
#define __IRQ_H__

#include <stdint.h>

// Uncomment to call debug[0xfe] with the bitmask of set IRQs at the start of the irq handler
#define DEBUG_IRQ

// This should match the value in start.S
#define INIT_IRQS_MASK 0xfffffff8 // Only enable the internal CPU interrupts at startup

#define IRQ_TIMER 	0x1 // Timer Interrupt
#define IRQ_EBREAK 	0x2 // EBREAK/ECALL or Illegal Instruction
#define IRQ_BUS_ERR 0x4 // BUS Error (Unalign Memory Access) + Used for invalid memory address

#define IRQ_UART_RX     0x8  // UART Char recieved
#define IRQ_UART_RX_ERR 0x10 // UART error recieved

#ifdef IRQ_IMPL
extern uint32_t irq_mask;
#else
extern const uint32_t irq_mask;
#endif

uint32_t set_irq_mask(uint32_t new_mask);
uint32_t *irq(uint32_t *regs, uint32_t irqs);

#endif // __IRQ_H__
