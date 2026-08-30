
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
#include "irq_vec_rv32e.S"
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
// Word alignment is all this block needs: irq_vec_rv32e.S reaches both labels
// with a lui/addi pair, which places no constraint on the low bits. The 0x200
// this used to ask for cost up to 512 bytes of pure fill in front of the
// section - against a 4 KiB RAM that alone overflowed the ram.ld link.
.balign 4
irq_regs:
	// registers are saved to this memory region during interrupt handling
	// the program counter is saved as register 0
#ifdef ENABLE_FASTIRQ
	.fill 12,4 // We need less storage for this since we aren't saving all regs
#else
	.fill 16,4
#endif

	// Stack for the interrupt handler. 64 words, sized from the deepest path
	// the handler can actually take - the bus-error/ebreak report in irq():
	//
	//   irq 12 + printf 28 + g_vfprintf 52 + emit_num 64 + emit_run 16
	//     + emit 8 + sink 8  ~= 190 bytes
	//
	// (frame sizes from gcc -fstack-usage). 256 bytes leaves that a third
	// again in headroom. Re-measure before adding anything that prints from
	// interrupt context.
	.fill 64,4
irq_stack:

#endif
