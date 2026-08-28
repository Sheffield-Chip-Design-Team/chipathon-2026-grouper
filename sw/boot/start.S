
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
// 16 is all this needs: irq_vec.S reaches both irq_regs and irq_stack through
// lui %hi + addi %lo, so neither label has an alignment requirement beyond the
// word accesses used to save and restore the context.
//
// It used to be .balign 0x200, which cost the firmware far more than the
// padding itself. .irq is the last section in RAM (sw/boot/ram.ld), so a
// 512-byte alignment quantised the whole image: _eirq became
// align(_ebss, 512) + 560, which capped a RAM-linked image at _ebss <= 3072
// of the 4 KiB and threw away up to 511 bytes of the gap. At 16 the cap is
// _ebss <= 3536 - ~460 more bytes for the test itself, which is the
// difference between a top-level software test in sw/tests fitting and not.
.balign 16
irq_regs:
	// registers are saved to this memory region during interrupt handling
	// the program counter is saved as register 0
#ifdef ENABLE_FASTIRQ
#ifdef __riscv_e
	// RV32E: x16-x31 do not exist, so slots 12-17 are never written by
	// irq_vec.S. Reserve only what is used.
	.fill 12,4
#else
	.fill 18,4 // We need less storage for this since we aren't saving all regs
#endif
#else
	.fill 32,4
#endif

	// Stack for the interrupt handler. 96 words = 384 bytes.
	//
	// Measured worst case is ~256 bytes: the deepest chain is
	// irq -> printf -> g_vfprintf -> emit_num -> emit_run -> emit plus the
	// sink's indirect write (~196), and the fault path can be entered twice
	// because the report below runs with interrupts live - but only twice,
	// because irq.c's `faulting` guard sends the second entry straight to
	// g_sim_exit(). That leaves ~128 bytes of margin.
	//
	// It was 128 words. The 128 bytes recovered go to the main stack, which
	// is whatever is left between _eirq and _estack - and on a RAM-linked
	// image (sw/boot/ram.ld) that is the scarce resource, not this.
	.fill 96,4
irq_stack:

#endif
