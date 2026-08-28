#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of sw/src/lib, part 3 of 3: the numeric parsing in
// gstr.c - strtoul across bases, its end pointer, and atoi on top of it.
//
// The memory block primitives and runtime helpers are in test_stdlib_mem.c,
// the string functions in test_stdlib_str.c. The three-way split is a RAM
// budget, not a taxonomy: the `default` target links a RAM-resident image
// (sw/boot/ram.ld) where code, rodata, data, bss and the stack share 4 KiB,
// and the whole of the former test_stdlib_str.c overflowed it by 2 KiB.

static void test_strtoul(void) {
  char *end;

  G_CHECK_EQ(strtoul("1234", NULL, 10), 1234);
  G_CHECK_EQ(strtoul("ff", NULL, 16), 255);
  G_CHECK_EQ(strtoul("0xff", NULL, 0), 255);      // base inferred from prefix
  G_CHECK_EQ(strtoul("0b1010", NULL, 0), 10);
  G_CHECK_EQ(strtoul("  -12", NULL, 10), (uint32_t) -12);
  G_CHECK_EQ(atoi("-99"), -99);

  // Stops at the first character not in the base, and reports where.
  G_CHECK_EQ(strtoul("12x", &end, 10), 12);
  G_CHECK(end != NULL && *end == 'x');

  // Nothing parsed - end comes back pointing at the original string.
  G_CHECK_EQ(strtoul("zz", &end, 10), 0);
  G_CHECK(end != NULL && *end == 'z');
}

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("stdlib_strtoul");

  test_strtoul();

  return g_test_end();
}
