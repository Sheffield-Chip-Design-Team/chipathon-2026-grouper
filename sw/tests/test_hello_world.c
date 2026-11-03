#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

// Interactive echo test. The top-level testbench drives this by sending
// "test\n" then "exit\n" over UART RX, each keyed off seeing a newline from
// the DUT (hw/tb/top/grouper_soc_hello_tb.sv), so the expected transcript is:
//
//     Hello World!
//     Bye!

int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  init_uart();

  g_test_begin("hi Mohammad");
  return g_test_end();
}
