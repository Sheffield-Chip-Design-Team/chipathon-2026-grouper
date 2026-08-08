#ifndef __GTIME_H__
#define __GTIME_H__

#include <stdint.h>

#include "soc.h"

// Cycle counting and delays.
//
// picorv32 is instantiated with ENABLE_COUNTERS and ENABLE_COUNTERS64 set
// (hw/rtl/cpu_ss.sv), so rdcycle/rdcycleh and rdinstret are real instructions
// on this core. Without those parameters they would trap as illegal
// instructions.
//
// Note BARREL_SHIFTER is 0: shifts cost a cycle per bit position, so anything
// timed with these is measuring a core where shifting is expensive.

static inline uint32_t g_cycles(void) {
    uint32_t v;
    __asm__ volatile ("rdcycle %0" : "=r" (v));
    return v;
}

static inline uint32_t g_instret(void) {
    uint32_t v;
    __asm__ volatile ("rdinstret %0" : "=r" (v));
    return v;
}

// Re-reads the high word to catch a carry landing between the two halves.
static inline uint64_t g_cycles64(void) {
    uint32_t hi, lo, hi2;

    do {
        __asm__ volatile ("rdcycleh %0" : "=r" (hi));
        __asm__ volatile ("rdcycle  %0" : "=r" (lo));
        __asm__ volatile ("rdcycleh %0" : "=r" (hi2));
    } while (hi != hi2);

    return ((uint64_t) hi << 32) | lo;
}

// Spins until the cycle counter has advanced by n. Accurate to the loop
// overhead, and wrap-safe because the subtraction is modulo 2^32.
static inline void g_delay_cycles(uint32_t n) {
    uint32_t start = g_cycles();

    while ((g_cycles() - start) < n) {}
}

static inline void g_delay_us(uint32_t us) {
    g_delay_cycles(us * (SYS_CLK_HZ / 1000000u));
}

static inline void g_delay_ms(uint32_t ms) {
    while (ms-- > 0) g_delay_us(1000);
}

#endif // __GTIME_H__
