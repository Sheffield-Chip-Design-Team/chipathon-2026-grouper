#include <stdint.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "irq.h"

// Scratch repro: narrow down the bus error that test_stdlib_str.c hits at the
// second memmove in test_mem().

int main(void) {
  char b[8];

  set_irq_mask(0xfffffff8);   // bus error / ebreak / timer enabled
  init_uart();

  puts("repro: start");

  memcpy(b, "abcdefg", 8);
  puts("repro: memcpy ok");

  memmove(b + 2, b, 5);       // forward-overlap: dst above src
  puts("repro: memmove up ok");

  memcpy(b, "abcdefg", 8);
  memmove(b, b + 2, 5);       // backward-overlap: dst below src
  puts("repro: memmove down ok");

  printf("repro: b = %s\n", b);
  g_sim_exit();
}
