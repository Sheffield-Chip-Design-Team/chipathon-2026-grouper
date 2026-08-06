#include <stdint.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Exercises the CPU's mul/div-free integer path and the call stack via deep
// recursion, and prints through the library's printf on the way.

int fibonacci(int n) {
  if (n <= 1) {
    return n;
  } else {
    return fibonacci(n - 1) + fibonacci(n - 2);
  }
}

int main(void) {
  uint32_t fib = 0;

  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("fibonacci");

  for (int i = 0; i < 10; i++) {
    fib = fibonacci(i);
    printf("Fibonacci [%d] = %lu\n", i, (unsigned long) fib);
  }

  G_CHECK_EQ(fib, 34);

  // Prints the TEST_RESULT line, drains the UART and stops the simulation.
  return g_test_end();
}
