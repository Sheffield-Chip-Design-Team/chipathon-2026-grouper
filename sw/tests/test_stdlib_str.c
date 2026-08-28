#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of sw/src/lib, part 2 of 3: the NUL-terminated
// string functions in gstr.c - length, comparison, copy and search.
//
// The memory block primitives and runtime helpers are in test_stdlib_mem.c,
// the numeric parsing in test_stdlib_strtoul.c. The three-way split is a RAM
// budget, not a taxonomy: the `default` target links a RAM-resident image
// (sw/boot/ram.ld) where code, rodata, data, bss and the stack share 4 KiB,
// and the whole of the former test_stdlib_str.c overflowed it by 2 KiB.

static char buf[32];

static void test_str(void) {
  G_CHECK_EQ(strlen(""), 0);
  G_CHECK_EQ(strlen("abcd"), 4);
  G_CHECK_EQ(strnlen("abcd", 2), 2);

  G_CHECK_EQ(strcmp("abc", "abc"), 0);
  G_CHECK(strcmp("abc", "abd") < 0);
  G_CHECK(strcmp("abd", "abc") > 0);

  G_CHECK_EQ(strncmp("abcX", "abcY", 3), 0);
  G_CHECK(strncmp("abcX", "abcY", 4) != 0);
  G_CHECK_EQ(strncmp("", "", 4), 0);

  strcpy(buf, "hello");
  G_CHECK_EQ(strlen(buf), 5);
  G_CHECK(strchr(buf, 'l') == buf + 2);     // first match, not the second
  G_CHECK(strchr(buf, 'z') == NULL);
  G_CHECK(strchr(buf, '\0') == buf + 5);    // libc: the terminator matches
}

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("stdlib_str");

  test_str();

  return g_test_end();
}
