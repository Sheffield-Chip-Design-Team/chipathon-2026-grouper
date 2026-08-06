#ifndef __DEBUG_H__
#define __DEBUG_H__

#include <stdint.h>
#include <stdbool.h>

// NOTE: DEBUG is deliberately NOT defined here - it is supplied by the build
// (sw/scripts/build_fw.sh --debug passes -DDEBUG). Defining it unconditionally
// would make the no-op fallbacks below unreachable, and would emit debug
// traffic to a peripheral that only exists under the DEBUG_PERIPH ifdef.

#ifdef DEBUG
// Define the raw base address values for the i/o devices
#define AHB_DEBUG_BASE                          0xf0002000
#define DEBUG_CHAR_ADDR (AHB_DEBUG_BASE + 0x3FF)

//////////////////////////////////////////////////////////////////
// Functions provided to access i/o devices
//////////////////////////////////////////////////////////////////

static inline void debug(uint16_t address, uint32_t value) {
    volatile uint32_t* DEBUG_REGS = (volatile uint32_t*) AHB_DEBUG_BASE;
    DEBUG_REGS[address] = value;
}
static inline void debug_char(char value) {
    volatile uint8_t* DEBUG_CHAR_REG = (volatile uint8_t *) DEBUG_CHAR_ADDR;
    *DEBUG_CHAR_REG = value;
}
static inline void debug_str(const char *s) {
    while (*s != 0) debug_char(*(s++));
}
void debug_dec(unsigned int val);
void debug_hex(unsigned int val, int digits);
#else
#define UNUSED(x) (void)(x)
#define debug(a,v) (UNUSED(a),UNUSED(v))
#define debug_char(v) (UNUSED(v))
#define debug_str(v) (UNUSED(v))
#define debug_dec(v) (UNUSED(v))
#define debug_hex(v, d) (UNUSED(v), UNUSED(d))
#endif

#endif // __DEBUG_H__