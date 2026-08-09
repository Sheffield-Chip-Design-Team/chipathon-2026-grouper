
// IRQ Config:
#define ENABLE_IRQ
#define ENABLE_QREGS
// Only save registers in IRQ wrapper that are to be saved by the caller in
// the RISC-V ABI, with the excpetion of the stack pointer. The IRQ handler
// will save the rest if necessary. I.e. skip x3, x4, x8, x9, and x18-x27.
#define ENABLE_FASTIRQ

// Include custom IRQ instructions
#include "custom_ops.S"

.section .reset.text, "ax"
.global reset_vec
#ifdef ENABLE_IRQ
.global irq
#endif

#define INIT_IRQS_MASK 0xfffffff8 // Only enable the internal CPU interrupts at startup

reset_vec:
	// no more than 16 bytes here !
#ifdef ENABLE_IRQ
    // picorv32_waitirq_insn(zero) // Dont wait for an irq
    li x1, INIT_IRQS_MASK // This is a pseudo-instruction, it will actually load -8 into x1 (ra), instead of using 2 instructions
	picorv32_maskirq_insn(zero, x1)
#endif
	j start

#ifdef ENABLE_IRQ
#include "irq_vec.S"
#endif

start:
    .cfi_startproc
    .cfi_undefined ra
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _estack
    add s0, sp, zero
    jal zero, ResetHandler
    .cfi_endproc
    // .end // Do not end the file here

#ifdef ENABLE_IRQ

.section .irq.regs, "aw", @nobits
.balign 0x200
irq_regs:
	// registers are saved to this memory region during interrupt handling
	// the program counter is saved as register 0
#ifdef ENABLE_FASTIRQ
	.fill 18,4 // We need less storage for this since we aren't saving all regs
#else
	.fill 32,4
#endif

	// stack for the interrupt handler
	.fill 128,4
irq_stack:

#endif
