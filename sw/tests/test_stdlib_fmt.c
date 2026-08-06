#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of the formatter in sw/src/lib/gio.c. Everything
// here runs through snprintf and compares against expected strings, so the
// formatter is verified against buffers rather than against whatever comes
// out of the UART.
//
// Split from test_stdlib_str.c only because of ROM: the two together do not
// fit the 8 KiB window in sw/soc.ld alongside the library.

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
}

static void test_width_and_flags(void) {
  // The reason width support was added: readable register dumps.
  snprintf(buf, sizeof(buf), "%08x", 0x1234u);
  G_CHECK_STR(buf, "00001234");

  snprintf(buf, sizeof(buf), "[%5d][%-5d]", 42, 42);
  G_CHECK_STR(buf, "[   42][42   ]");

  snprintf(buf, sizeof(buf), "[%5s][%-5s][%.2s]", "ab", "ab", "abcd");
  G_CHECK_STR(buf, "[   ab][ab   ][ab]");

  snprintf(buf, sizeof(buf), "[%+d][% d][%+d]", 7, 7, -7);
  G_CHECK_STR(buf, "[+7][ 7][-7]");

  // Zero padding must sit after the sign, never before it.
  snprintf(buf, sizeof(buf), "%05d", -42);
  G_CHECK_STR(buf, "-0042");

  // '*' takes the width from the argument list; a negative one left-aligns.
  snprintf(buf, sizeof(buf), "[%*d][%*d]", 4, 7, -4, 7);
  G_CHECK_STR(buf, "[   7][7   ]");

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

static void test_sinks(void) {
  g_buf_ctx_t ctx;
  g_sink_t    sink = g_sink_buf(&ctx, buf, sizeof(buf));

  g_fprintf(&sink, "to a %s", "buffer");
  G_CHECK_STR(buf, "to a buffer");
  G_CHECK_EQ(ctx.len, 11);
}

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("stdlib_fmt");

  test_conversions();
  test_width_and_flags();
  test_snprintf_bounds();
  test_sinks();

  return g_test_end();
}
