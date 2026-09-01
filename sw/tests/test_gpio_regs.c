#include <stdint.h>
#include <stdbool.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "gpio.h"

#include "irq.h"

// SoC-level GPIO test, part 1 of 2: the register-visible behaviour.
//
// Split out of the former test_gpio.c, which no longer fit the 4 KiB RAM
// window the `default` target links against (sw/boot/ram.ld). This half is
// entirely self-checking and needs no stimulus, so it runs under the generic
// test_firmware_runs leg; the pad-electrical registers, the GPIO_SYNC_EN_N
// bypass and the pattern streaming - all of which need the testbench to drive
// or observe them - are in test_gpio_echo.c.
//
// Everything here scores itself against the pad model in
// hw/tb/top/test_soc.py: a pad the SoC drives loops back to its own input, a
// pad with its input buffer disabled reads 0, and anything else follows what
// the testbench drives. That loopback is what lets this test check its own
// outputs without a bus back to the testbench.

// Pads 0-7 are driven by the testbench, pads 8-15 are driven by us.
#define OUT_PADS  0xFF00u

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


int main(void) {
  set_irq_mask(0xfffffff8);
  debug_str("CPU Ready\n");
  init_uart();

  g_test_begin("gpio_regs");

  test_reset_state();
  test_input_enable();
  test_output_drive();
  test_set_clear();
  test_altsel_releases_pad();

  return g_test_end();
}
