#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"

#include "irq.h"

static char rx_buffer[32] = {0};

void process_cmd(void) {
  if (rx_buffer[0] == 0) return;

  if (strcmp(rx_buffer, "exit") == 0) {
    puts("Bye!");
    g_sim_exit();
  }

  printf("Hello %s!\n", rx_buffer);
}

// The stack usage can be decreased to 0, by marking the function as "naked",
// this means the function doesn't do any register preservation, etc. (or any other compiler prologue/epilogue code)
// This may break things, so should only really be used on non-returning functions
// __attribute__ ((naked))
int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  puts("What is your name?");

  while (1) {
    // No echo: the top-level testbench keys the next line it sends off
    // seeing a newline from us, and the RX FIFO is only 4 deep - echoing
    // would have it start sending "exit\n" while we are still transmitting
    // the reply, and the tail of the line would be dropped.
    g_getline(rx_buffer, sizeof(rx_buffer), false);
    process_cmd();
    rx_buffer[0] = 0;
  }
}
