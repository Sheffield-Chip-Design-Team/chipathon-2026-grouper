#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "uart.h"
#include "debug.h"

#include "irq.h"

static inline void uart_tx_str(const char *s) {
  while (*s != 0) uart_tx(*(s++));
}

static char rx_buffer[32] = {0};
static uint8_t rx_buf_index = 0;

int strncmp(const char *s1, const char *s2, register size_t n) {
  register unsigned char u1, u2;
  while (n-- > 0) {
    u1 = (unsigned char) *s1++;
    u2 = (unsigned char) *s2++;
    if (u1 != u2) return u1 - u2;
    if (u1 == '\0') return 0;
  }
  return 0;
}

void process_cmd(void) {
  if (rx_buf_index == 0) return;

  if (strncmp(rx_buffer, "exit", rx_buf_index) == 0) {
    uart_tx_str("Bye!\n");
    // Wait for UART to finish transmitting
    while (uart_status().s.status_tx_active != 0) {}
    debug(0xff, 0xDEAD600D);
  }

  uart_tx_str("Hello "); 
  uart_tx_str(rx_buffer);
  uart_tx_str("!\n");
}

// The stack usage can be decreased to 0, by marking the function as "naked",
// this means the function doesn't do any register preservation, etc. (or any other compiler prologue/epilogue code)
// This may break things, so should only really be used on non-returning functions
// __attribute__ ((naked))
int main(void) {
  set_irq_mask(0xfffffff8); // Enable system IRQs (not UART or other IRQs)
  debug_str("CPU Ready\n");
  init_uart();

  uart_tx_str("What is your name?\n");

  while (1) {
    while (uart_status().s.status_rx_empty == 0) {
      uint8_t c = uart_rx();
      if (c == '\n') {
        process_cmd();
        rx_buffer[0] = 0;
        rx_buf_index = 0;
      } else if (c != 0 && rx_buf_index < (sizeof(rx_buffer) - 1)) {
        rx_buffer[rx_buf_index++] = c;
        rx_buffer[rx_buf_index] = 0;
      }
    }
  }
}
