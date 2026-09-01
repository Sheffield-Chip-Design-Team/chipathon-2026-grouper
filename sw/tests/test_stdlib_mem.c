#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Self-checking exercise of sw/src/lib, part 1 of 3: the memory block
// primitives in gstr.c, plus the two small runtime helpers - cycle counting
// (gtime.h) and register polling (greg.h).
//
// The string functions are in test_stdlib_str.c and the numeric parsing in
// test_stdlib_strtoul.c. The three-way split is a RAM budget, not a taxonomy:
// the `default` target links a RAM-resident image (sw/boot/ram.ld) where
// code, rodata, data, bss and the stack share 4 KiB, and the whole of the
// former test_stdlib_str.c overflowed it by 2 KiB.

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
  // 5 bytes, so the comparison is over 5. This used to ask for 6, which pulled
  // in the NUL of the literal and compared it against a byte memmove was never
  // asked to write - it failed on correct behaviour. The leg was carried in
  // .github/sim-ci-targets.yaml as a "known bus error at the second memmove";
  // there is no bus error, the expectation was simply wrong.
  G_CHECK_EQ(memcmp(b, "cdefg", 5), 0);
  // And nothing past n is touched: b[5] still holds what memcpy left there.
  G_CHECK_EQ((uint8_t) b[5], 'f');
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

  g_test_begin("stdlib_mem");

  test_mem();
  test_time();
  test_reg_poll();

  return g_test_end();
}
