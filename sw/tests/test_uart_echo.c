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

static char rx_buffer[32] = {0};

static void process_cmd(void) {
  if (rx_buffer[0] == 0) return;

  if (strcmp(rx_buffer, "exit") == 0) {
    puts("Bye!");
    g_test_end();
  }

  printf("Hello %s!\n", rx_buffer);
}

int main(void) {

  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)

  debug_str("CPU Ready\n");
  
  init_uart();

  g_test_begin("uart_echo");
  
  while (1) {
    g_getline(rx_buffer, sizeof(rx_buffer), false);
    process_cmd();
    rx_buffer[0] = 0;
  }
}
