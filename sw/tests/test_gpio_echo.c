#include <stdint.h>
#include <stdbool.h>

#include "grouper_std_lib.h"
#include "uart.h"
#include "debug.h"
#include "gpio.h"

#include "irq.h"

// SoC-level GPIO test, part 2 of 2: the pad-electrical registers and the
// pattern echo.
//
// Split out of the former test_gpio.c, which no longer fit the 4 KiB RAM
// window the `default` target links against (sw/boot/ram.ld). The
// register-visible half is test_gpio_regs.c.
//
// This is the half that needs the testbench to do something, so it is driven
// by test_gpio_patterns in hw/tb/top/test_soc.py rather than by the generic
// test_firmware_runs leg:
//
//   - the pad-electrical registers (pu/pd/cs/sl) only leave the SoC, so
//     firmware cannot read back what reached the pads. This writes a distinct
//     nibble pattern to each and the testbench's check_pad_config() confirms
//     it arrives. Keeping that write here is what pairs it with the leg that
//     performs the check.
//   - the GPIO_SYNC_EN_N bypass, which selects between the synchronised and
//     the direct input path. It sits here rather than with the other register
//     tests because it exercises the input side, which is what the echo below
//     also depends on.
//   - the echo loop then streams patterns: the testbench drives the low byte
//     and this echoes it back on the high byte, so the testbench can score
//     the round trip. It waits for each echo before driving the next pattern,
//     so nothing is missed.

// Pads 0-7 are driven by the testbench, pads 8-15 are driven by us.
#define IN_PADS   0x00FFu
#define OUT_PADS  0xFF00u

// Must match GPIO_ECHO_COUNT in hw/tb/top/test_soc.py. The testbench drives
// exactly this many patterns and we echo exactly this many.
#define GPIO_ECHO_COUNT 64

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

static void test_sync_bypass(void) {
  // Both paths must carry the same value. The two-cycle latency difference is
  // far below anything firmware can observe - that is measured in the
  // testbench, not here.
  //
  // GPIO_IE resets to zero (ie_r in hw/rtl/gpio/ahb_gpio_ctrl.sv), and in this
  // image nothing has enabled the input buffers yet - the test that used to
  // run before this one is in test_gpio_regs.c now - so read-back through the
  // pad loopback needs them turned on here.
  gpio_set_ie(GPIO_PAD_MASK);
  gpio_set_oe(OUT_PADS);
  gpio_write(0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, 0x0000);   // synchronised
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, GPIO_PAD_MASK);  // bypassed
  G_CHECK_EQ(gpio_in() & OUT_PADS, 0xC300);

  g_wr32(GPIO_SYNC_EN_N_ADDR, 0x0000);
}

// Echo whatever the testbench drives on the low byte back out on the high
// byte, so it can score its own patterns.
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

  g_test_begin("gpio_echo");

  test_pad_config_registers();
  test_sync_bypass();

  // Hand the input pads back to the testbench and drive only the high byte.
  gpio_set_ie(GPIO_PAD_MASK);
  gpio_set_oe(OUT_PADS);
  gpio_write(0x0000);

  echo_loop();

  return g_test_end();
}
