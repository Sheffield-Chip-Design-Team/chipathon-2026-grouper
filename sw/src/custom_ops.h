// C Macros for picorv32 custom opcodes.
// See custom_ops.S for the raw-assembly equivalents used from .S files.
//
// The upstream picorv32 pattern of substituting a GCC-allocated register
// into a `.word` encoding via an asm operand modifier (%N0/%N1) does not
// work on this toolchain: the 'N' modifier ICEs riscv64-unknown-elf-gcc
// 14.2.0 ("internal compiler error: in reverse_condition, at jump.cc:536"),
// and even plain %0 substitution emits the register's assembler NAME
// (e.g. "a5") into the .word arithmetic expression, which GAS cannot
// evaluate. Instead, each macro pins its operand(s) to a fixed scratch
// register (t0 in, t1 out) via GCC named-register locals, so the register
// index is a compile-time constant (regnum_t0/regnum_t1). GCC's extended
// asm still transparently emits whatever mv/load/store is needed around it.

#ifndef __CUSTOM_OPS_H__
#define __CUSTOM_OPS_H__

#ifdef _MSC_VER
// Silence IDE warnings about __asm__ when C/C++ style set to MSVC
#define __asm__ __asm
#endif

#include <stdint.h>

#define regnum_q0   0
#define regnum_q1   1
#define regnum_q2   2
#define regnum_q3   3

#define regnum_t0   5
#define regnum_t1   6

#define __xstr(s) __str(s)
#define __str(s) #s

#define r_type_insn(_f7, _rs2, _rs1, _f3, _rd, _opc) \
    .word (((_f7) << 25) | ((_rs2) << 20) | ((_rs1) << 15) | ((_f3) << 12) | ((_rd) << 7) | ((_opc) << 0))

#define picorv32_getq_insn(_rd, _qs) \
    do { \
        register uint32_t __t1 __asm__("t1"); \
        __asm__ volatile ( \
            __xstr(r_type_insn(0b0000000, 0, regnum_ ## _qs, 0b100, regnum_t1, 0b0001011)) \
            : "=r" (__t1) \
        ); \
        (_rd) = __t1; \
    } while (0)

#define picorv32_setq_insn(_qd, _rs) \
    do { \
        register uint32_t __t0 __asm__("t0") = (uint32_t)(_rs); \
        __asm__ volatile ( \
            __xstr(r_type_insn(0b0000001, 0, regnum_t0, 0b010, regnum_ ## _qd, 0b0001011)) \
            :: "r" (__t0) \
        ); \
    } while (0)

#define picorv32_retirq_insn() \
    __asm__ volatile (__xstr(r_type_insn(0b0000010, 0, 0, 0b000, 0, 0b0001011)))

#define picorv32_maskirq_insn(_rd, _rs) \
    do { \
        register uint32_t __t0 __asm__("t0") = (uint32_t)(_rs); \
        register uint32_t __t1 __asm__("t1"); \
        __asm__ volatile ( \
            __xstr(r_type_insn(0b0000011, 0, regnum_t0, 0b110, regnum_t1, 0b0001011)) \
            : "=r" (__t1) : "r" (__t0) \
        ); \
        (_rd) = __t1; \
    } while (0)

#define picorv32_waitirq_insn(_rd) \
    do { \
        register uint32_t __t1 __asm__("t1"); \
        __asm__ volatile ( \
            __xstr(r_type_insn(0b0000100, 0, 0, 0b100, regnum_t1, 0b0001011)) \
            : "=r" (__t1) \
        ); \
        (_rd) = __t1; \
    } while (0)

#define picorv32_timer_insn(_rd, _rs) \
    do { \
        register uint32_t __t0 __asm__("t0") = (uint32_t)(_rs); \
        register uint32_t __t1 __asm__("t1"); \
        __asm__ volatile ( \
            __xstr(r_type_insn(0b0000101, 0, regnum_t0, 0b110, regnum_t1, 0b0001011)) \
            : "=r" (__t1) : "r" (__t0) \
        ); \
        (_rd) = __t1; \
    } while (0)

#endif // __CUSTOM_OPS_H__
