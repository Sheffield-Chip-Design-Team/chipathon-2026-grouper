#ifndef __GREG_H__
#define __GREG_H__

#include <stdbool.h>
#include <stdint.h>

#include "gtime.h"

// Memory-mapped register access.
//
// The point of g_poll is the timeout. Bring-up code that spins forever on a
// status bit turns a broken peripheral into a simulation that runs to
// TB_TIMEOUT with nothing printed; g_poll gives it back as a false return the
// caller can report.

static inline uint32_t g_rd32(uint32_t addr) {
    return *(volatile uint32_t *) addr;
}

static inline void g_wr32(uint32_t addr, uint32_t val) {
    *(volatile uint32_t *) addr = val;
}

static inline uint8_t g_rd8(uint32_t addr) {
    return *(volatile uint8_t *) addr;
}

static inline void g_wr8(uint32_t addr, uint8_t val) {
    *(volatile uint8_t *) addr = val;
}

static inline void g_set_bits(uint32_t addr, uint32_t mask) {
    g_wr32(addr, g_rd32(addr) | mask);
}

static inline void g_clr_bits(uint32_t addr, uint32_t mask) {
    g_wr32(addr, g_rd32(addr) & ~mask);
}

// Waits for (*addr & mask) == val. Returns true on match, false if
// timeout_cycles elapsed first. A timeout_cycles of 0 means wait forever.
static inline bool g_poll(uint32_t addr, uint32_t mask, uint32_t val,
                          uint32_t timeout_cycles) {
    uint32_t start = g_cycles();

    for (;;) {
        if ((g_rd32(addr) & mask) == val) return true;
        if (timeout_cycles != 0 && (g_cycles() - start) >= timeout_cycles) return false;
    }
}

#endif // __GREG_H__
