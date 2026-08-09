#include <stdint.h>
#include <stdbool.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "gpio.h"

#include "irq.h"

// SoC-level GPIO test.
//
// Runs against the cocotb testbench in hw/tb/top/test_soc.py, which models a
// pad cell: a pad the SoC drives loops back to its own input, a pad with its
// input buffer disabled reads 0, and everything else follows what the
// testbench is driving. That loopback is what lets this test check its own
// outputs without a bus back to the testbench.
//
//   fusesoc run --no-export --target=tb_top_cocotb grouper_soc
//
// Phase 2 streams patterns from the testbench: the low byte is driven by the
// testbench, and this firmware echoes it back on the high byte. The testbench
// waits for each echo before driving the next pattern, so nothing is missed.

// Pads 0-7 are driven by the testbench, pads 8-15 are driven by us.
#define IN_PADS   0x00FFu
#define OUT_PADS  0xFF00u

// Must match GPIO_ECHO_COUNT in hw/tb/top/test_soc.py. The testbench drives
// exactly this many patterns and we echo exactly this many.
#define GPIO_ECHO_COUNT 64

static void test_reset_state(void) {
  // Nothing driven, no pad claimed by a peripheral, no pad locked.
  G_CHECK_EQ(g_rd32(GPIO_OUT_ADDR) & GPIO_PAD_MASK, 0);
  G_CHECK_EQ(g_rd32(GPIO_OE_ADDR) & GPIO_PAD_MASK, 0);
  G_CHECK_EQ(g_rd32(GPIO_ALTSEL_ADDR) & GPIO_PAD_MASK, 0);
  G_CHECK_EQ(g_rd32(GPIO_RO_MASK_ADDR) & GPIO_PAD_MASK, 0);
}

static void test_input_enable(void) {
  // With the input buffer off, the pad reads 0 however it is driven - the pad
  // cell does that gating, which is why ahb_gpio_ctrl does not mask GPIO_IN
  // with GPIO_IE itself.
  gpio_set_ie(0x0000);
  gpio_set_oe(OUT_PADS);
  gpio_write(0xFF00);
  G_CHECK_EQ(gpio_in(), 0x0000);

  gpio_set_ie(GPIO_PAD_MASK);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xFF00);
}

static void test_output_drive(void) {
  gpio_set_ie(GPIO_PAD_MASK);
  gpio_set_oe(OUT_PADS);

  // Whatever we drive on the output pads comes straight back through the
  // testbench's loopback.
  gpio_write(0xA500);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xA500);

  gpio_write(0x5A00);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0x5A00);

  // A pad with its output disabled follows the testbench, not GPIO_OUT.
  gpio_set_oe(0x0000);
  gpio_write(0xFF00);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0x0000);

  gpio_set_oe(OUT_PADS);
}

static void test_set_clear(void) {
  gpio_write(0x0000);
  gpio_set_pins(0x0300);
  G_CHECK_EQ(gpio_out(), 0x0300);

  gpio_clr_pins(0x0100);
  G_CHECK_EQ(gpio_out(), 0x0200);
}

static void test_altsel_releases_pad(void) {
  // Pad 15 is the spare - it has no alternate function, so selecting one
  // hands the pad to a source that drives nothing with its output enable low.
  // The pad must stop following GPIO_OUT, which is a direct check that the
  // mux in io_ss switches ownership.
  gpio_set_oe(OUT_PADS);
  gpio_write(0xFF00);
  gpio_set_altsel(0x0000);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xFF00);

  gpio_set_altsel(1u << GPIO_PIN_SPARE);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0x7F00);

  gpio_set_altsel(0x0000);
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xFF00);
}

static void test_sync_bypass(void) {
  // Both paths must carry the same value. The two-cycle latency difference is
  // far below anything firmware can observe - that is measured in the
  // testbench, not here.
  gpio_set_oe(OUT_PADS);
  gpio_write(0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, 0x0000);   // synchronised
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, GPIO_PAD_MASK);  // bypassed
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, 0x0000);
}

static void test_pad_config_registers(void) {
  // These only leave the SoC - the testbench checks they reach the pads.
  g_wr32(GPIO_PU_ADDR, 0x000F);
  g_wr32(GPIO_PD_ADDR, 0x00F0);
  g_wr32(GPIO_CS_ADDR, 0x0F00);
  g_wr32(GPIO_SL_ADDR, 0xF000);

  G_CHECK_EQ(g_rd32(GPIO_PU_ADDR) & GPIO_PAD_MASK, 0x000F);
  G_CHECK_EQ(g_rd32(GPIO_PD_ADDR) & GPIO_PAD_MASK, 0x00F0);
  G_CHECK_EQ(g_rd32(GPIO_CS_ADDR) & GPIO_PAD_MASK, 0x0F00);
  G_CHECK_EQ(g_rd32(GPIO_SL_ADDR) & GPIO_PAD_MASK, 0xF000);
}

// Phase 2: echo whatever the testbench drives on the low byte back out on the
// high byte, so it can score its own patterns.
static void echo_loop(void) {
  uint32_t last = gpio_in() & IN_PADS;

  puts("GPIO_ECHO_READY");

  for (int i = 0; i < GPIO_ECHO_COUNT; i++) {
    uint32_t value;

    // The testbench guarantees consecutive patterns differ, so a change is a
    // reliable "next pattern has arrived" signal and no strobe is needed.
    do {
      value = gpio_in() & IN_PADS;
    } while (value == last);

    gpio_write(value << 8);
    last = value;
  }

  printf("GPIO_ECHO_DONE %d\n", GPIO_ECHO_COUNT);
}

int main(void) {
  set_irq_mask(0xfffffff8);
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("gpio");

  test_reset_state();
  test_input_enable();
  test_output_drive();
  test_set_clear();
  test_altsel_releases_pad();
  test_sync_bypass();
  test_pad_config_registers();

  // Hand the input pads back to the testbench and drive only the high byte.
  gpio_set_ie(GPIO_PAD_MASK);
  gpio_set_oe(OUT_PADS);
  gpio_write(0x0000);

  echo_loop();

  return g_test_end();
}
