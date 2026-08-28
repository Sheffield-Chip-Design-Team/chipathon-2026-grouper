#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of the formatter in sw/src/lib/gio.c, part 1 of 2:
// what each conversion specifier produces, and how snprintf behaves when the
// result does not fit.
//
// Field width, precision, flags and the sink plumbing are in
// test_stdlib_fmt_width.c. The split is a RAM budget, not a taxonomy: the
// `default` target links a RAM-resident image (sw/boot/ram.ld) and everything
// - code, rodata, data, bss and the stack - has to fit 4 KiB, which the two
// halves together no longer did.
//
// Everything here runs through snprintf and compares against expected
// strings, so the formatter is verified against buffers rather than against
// whatever comes out of the UART.

static char buf[64];

static void test_conversions(void) {
  snprintf(buf, sizeof(buf), "%d %i %u", -42, 42, 4000000000u);
  G_CHECK_STR(buf, "-42 42 4000000000");

  snprintf(buf, sizeof(buf), "%x %X %o %b", 0xdeadbeefu, 0xabcu, 8u, 5u);
  G_CHECK_STR(buf, "deadbeef ABC 10 101");

  snprintf(buf, sizeof(buf), "%c%s%%", 'a', "bc");
  G_CHECK_STR(buf, "abc%");

  // long is 32 bits on ilp32, so %lu and %u must agree.
  snprintf(buf, sizeof(buf), "%lu", 123456789ul);
  G_CHECK_STR(buf, "123456789");

  // INT_MIN must survive the negate-as-unsigned path.
  snprintf(buf, sizeof(buf), "%d", -2147483647 - 1);
  G_CHECK_STR(buf, "-2147483648");

  // Unknown specifiers are echoed back rather than swallowed.
  snprintf(buf, sizeof(buf), "%q");
  G_CHECK_STR(buf, "%q");

  // %p is a conversion, not a width - it always renders 0x + 8 hex digits.
  snprintf(buf, sizeof(buf), "%p", (void *) 0x2000);
  G_CHECK_STR(buf, "0x00002000");
}

static void test_snprintf_bounds(void) {
  char small[5];

  // Truncates to cap-1 characters, always terminates, and returns the length
  // it would have needed - C99 semantics.
  int n = snprintf(small, sizeof(small), "abcdefgh");
  G_CHECK_EQ(n, 8);
  G_CHECK_STR(small, "abcd");

  n = snprintf(small, sizeof(small), "ab");
  G_CHECK_EQ(n, 2);
  G_CHECK_STR(small, "ab");
}

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("stdlib_fmt_conv");

  test_conversions();
  test_snprintf_bounds();

  return g_test_end();
}
