#ifndef __GPIO_H__
#define __GPIO_H__

#include <stdint.h>
#include <stdbool.h>

#include "config.h"
#include "greg.h"

// GPIO mux control registers.
//
// Register map: planning/Hardware/design/blocks/GPIO Mux.md
// RTL:          hw/rtl/gpio/ahb_gpio_ctrl.sv
//
// Bit n of every register applies to pad n. Bits 31:16 are reserved.

#define GPIO_NUM_PADS  16
#define GPIO_PAD_MASK  0xFFFFu

#define GPIO_OUT_ADDR        (AHB_GPIO_BASE + 0x00)  // RW output data
#define GPIO_IN_ADDR         (AHB_GPIO_BASE + 0x04)  // RO live pad value
#define GPIO_OE_ADDR         (AHB_GPIO_BASE + 0x08)  // RW output enable
#define GPIO_ALTSEL_ADDR     (AHB_GPIO_BASE + 0x0C)  // RW alternate function select
#define GPIO_RO_MASK_ADDR    (AHB_GPIO_BASE + 0x10)  // RW read-only pad mask
#define GPIO_SYNC_EN_N_ADDR  (AHB_GPIO_BASE + 0x14)  // RW synchroniser bypass
#define GPIO_IE_ADDR         (AHB_GPIO_BASE + 0x18)  // RW input enable
#define GPIO_PU_ADDR         (AHB_GPIO_BASE + 0x1C)  // RW pull-up
#define GPIO_PD_ADDR         (AHB_GPIO_BASE + 0x20)  // RW pull-down
#define GPIO_CS_ADDR         (AHB_GPIO_BASE + 0x24)  // RW input type (0=CMOS, 1=Schmitt)
#define GPIO_SL_ADDR         (AHB_GPIO_BASE + 0x28)  // RW slew rate (0=fast, 1=slow)

// Pin assignment. Which alternate function each pad carries when its
// GPIO_ALTSEL bit is set - see hw/rtl/io_ss.sv, which is where this is
// actually encoded. Pad 15 has no alternate function.
#define GPIO_PIN_SPI_S_SS    0
#define GPIO_PIN_SPI_S_SCK   1
#define GPIO_PIN_SPI_S_MOSI  2
#define GPIO_PIN_SPI_S_MISO  3
#define GPIO_PIN_SPI_M_SS    4
#define GPIO_PIN_SPI_M_SCK   5
#define GPIO_PIN_SPI_M_MOSI  6
#define GPIO_PIN_SPI_M_MISO  7
#define GPIO_PIN_QSPI_SCK    8
#define GPIO_PIN_QSPI_CE_N0  9
#define GPIO_PIN_QSPI_CE_N1  10
#define GPIO_PIN_QSPI_SIO0   11
#define GPIO_PIN_QSPI_SIO1   12
#define GPIO_PIN_QSPI_SIO2   13
#define GPIO_PIN_QSPI_SIO3   14
#define GPIO_PIN_SPARE       15

// Every pad comes out of reset as an un-driven, un-pulled, synchronised input
// with its input buffer DISABLED. GPIO_IN reads 0 until GPIO_IE is set - this
// is the step most easily forgotten during bring-up.
static inline void gpio_set_ie(uint32_t mask)      { g_wr32(GPIO_IE_ADDR, mask); }
static inline void gpio_set_oe(uint32_t mask)      { g_wr32(GPIO_OE_ADDR, mask); }
static inline void gpio_set_altsel(uint32_t mask)  { g_wr32(GPIO_ALTSEL_ADDR, mask); }
static inline void gpio_set_ro_mask(uint32_t mask) { g_wr32(GPIO_RO_MASK_ADDR, mask); }

static inline uint32_t gpio_in(void)  { return g_rd32(GPIO_IN_ADDR) & GPIO_PAD_MASK; }
static inline uint32_t gpio_out(void) { return g_rd32(GPIO_OUT_ADDR) & GPIO_PAD_MASK; }

static inline void gpio_write(uint32_t value) { g_wr32(GPIO_OUT_ADDR, value); }

// Read-modify-write on the output register. Note these are not atomic against
// an interrupt handler that also drives GPIO.
static inline void gpio_set_pins(uint32_t mask) { g_set_bits(GPIO_OUT_ADDR, mask); }
static inline void gpio_clr_pins(uint32_t mask) { g_clr_bits(GPIO_OUT_ADDR, mask); }

#endif // __GPIO_H__
