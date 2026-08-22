#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// FIXME - these tests are now much bigger than 4k

// Self-checking exercise of the string/memory, timing and MMIO parts of
// sw/src/lib. The formatter has its own test in test_stdlib_fmt.c - split
// because the two together do not fit the 8 KiB ROM window in sw/soc.ld.

static char buf[32];

static void test_mem(void) {
  char a[8];
  char b[8];

  memset(a, 0x5a, sizeof(a));
  G_CHECK_EQ((uint8_t) a[0], 0x5a);
  G_CHECK_EQ((uint8_t) a[7], 0x5a);

  memcpy(b, "abcdefg", 8);
  G_CHECK_EQ(memcmp(b, "abcdefg", 8), 0);
  G_CHECK(memcmp(b, "abcdefh", 8) < 0);

  // Overlapping with the destination above the source - the case a naive
  // forward copy gets wrong.
  memcpy(b, "abcdefg", 8);
  memmove(b + 2, b, 5);
  G_CHECK_EQ(memcmp(b, "ababcde", 8), 0);

  // Overlapping the other way.
  memcpy(b, "abcdefg", 8);
  memmove(b, b + 2, 5);
  G_CHECK_EQ(memcmp(b, "cdefg", 6), 0);
}

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

static void test_time(void) {
  uint32_t start = g_cycles();

  g_delay_cycles(1000);
  // Wrap-safe: the subtraction is modulo 2^32.
  G_CHECK((g_cycles() - start) >= 1000);

  // rdinstret must advance too, or ENABLE_COUNTERS is not what we think.
  uint32_t i0 = g_instret();
  g_delay_cycles(100);
  G_CHECK((g_instret() - i0) > 0);
}

static void test_reg_poll(void) {
  uint32_t status = AHB_UART_BASE + UART_STATUS_ADDR * 4;

  // The transmitter is idle by now, so tx_empty is already set and g_poll
  // returns immediately.
  G_CHECK(g_poll(status, 1u << 0, 1u << 0, 10000));

  // rx_full can never be set here - nothing is feeding the receiver - so this
  // must come back false rather than spinning until TB_TIMEOUT.
  G_CHECK(!g_poll(status, 1u << 3, 1u << 3, 5000));
}

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("stdlib_str");

  test_mem();
  test_str();
  test_strtoul();
  test_time();
  test_reg_poll();

  return g_test_end();
}
