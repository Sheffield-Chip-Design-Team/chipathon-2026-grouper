#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of the formatter in sw/src/lib/gio.c, part 2 of 2:
// field width, precision and the flag characters, plus the output sinks
// g_fprintf writes through.
//
// The conversion specifiers themselves and snprintf's truncation contract are
// in test_stdlib_fmt_conv.c. The split is a RAM budget, not a taxonomy: the
// `default` target links a RAM-resident image (sw/boot/ram.ld) and everything
// - code, rodata, data, bss and the stack - has to fit 4 KiB, which the two
// halves together no longer did.

static char buf[64];

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

  g_test_begin("stdlib_fmt_width");

  test_width_and_flags();
  test_sinks();

  return g_test_end();
}
