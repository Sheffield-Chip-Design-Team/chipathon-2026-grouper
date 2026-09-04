#ifndef __GTEST_H__
#define __GTEST_H__

#include <stdbool.h>
#include <stdint.h>

// A minimal self-checking test harness for the firmware in sw/tests.
//
// g_test_end() prints a single machine-readable summary line:
//
//     TEST_RESULT: PASS (12/12)
//     TEST_RESULT: FAIL (11/12)
//
// That line is what makes a plain tb_top run legible, since debug() - and so
// the early $finish - only exists in a --debug build against a DEBUG_PERIPH
// target. A non-debug run still prints the result before the testbench times
// out.

void g_test_begin(const char *name);

// The checks take __LINE__ but deliberately not __FILE__: an image has
// exactly one test translation unit, whose name g_test_begin() already
// printed, so the file would be redundant - and at ~45 call sites the extra
// argument costs real ROM against the 8 KiB window.
bool g_check(bool cond, const char *expr, int line);
bool g_check_eq_u(uint32_t got, uint32_t expect, const char *expr, int line);
bool g_check_eq_str(const char *got, const char *expect, const char *expr,
                    int line);

#define G_CHECK(cond)          g_check((cond), #cond, __LINE__)
#define G_CHECK_EQ(got, exp)   g_check_eq_u((uint32_t)(got), (uint32_t)(exp), \
                                            #got, __LINE__)
#define G_CHECK_STR(got, exp)  g_check_eq_str((got), (exp), #got, __LINE__)

// Tagged variants. Same checks, but the caller supplies a short label instead
// of the stringified expression. A check on a call with a long argument list
// costs ~85 bytes of .rodata when stringified, which a test linked for the
// 4 KiB RAM (sw/boot/ram.ld) cannot always afford. The FAIL line still carries
// __LINE__, so the call site is identified either way - the tag only has to
// distinguish the checks from each other at a glance.
#define G_CHECK_T(cond, tag)         g_check((cond), (tag), __LINE__)
#define G_CHECK_EQ_T(got, exp, tag)  g_check_eq_u((uint32_t)(got), \
                                                  (uint32_t)(exp), (tag), \
                                                  __LINE__)

// Prints the TEST_RESULT line and does not return - it hands off to
// g_sim_exit(). Returns int only so `return g_test_end();` reads naturally.
int g_test_end(void) __attribute__((noreturn));

// Drains the UART transmitter, then asks the testbench to stop. This is the
// single home of the drain-then-magic-value idiom that used to be copied into
// every test. Without -DDEBUG the debug() write compiles away and this just
// parks the CPU until the testbench's own timeout.
void g_sim_exit(void) __attribute__((noreturn));

#endif // __GTEST_H__
