#ifndef __CONFIG_H__
#define __CONFIG_H__

// SoC-wide constants: the clock the design is run at, and the address map.
// Everything here describes the hardware, not any one driver - drivers
// include this rather than defining their own copies.

// Core clock. The UART baud divisor is computed against this, and gtime.h's
// delay helpers convert microseconds with it, so it must match the clock the
// SoC is actually run at. The top-level testbench cross-checks its own
// CLK_FREQ localparam against this value (hw/tb/top/grouper_soc_hello_tb.sv).
#define SYS_CLK_HZ  10000000

// --- Memory ---------------------------------------------------------------
//
// ROM and RAM are not fabric slaves: cpu_ss serves them from picorv32's native
// memory port and only puts 0x8000_0000 and up on HADDR. The decode is on
// mem_la_addr[31:29] in hw/rtl/cpu_ss.sv, so each region aliases across its
// whole 512 MiB slice - the bases below are the intended aliases.
//
// Which of ROM and RAM answers at 0x0000_0000 depends on the bank switch: it
// resets to 0 (ROM at zero, so the CPU fetches its reset vector from ROM), and
// writing 1 to BANK_SWITCH_ADDR swaps them and resets the CPU, so it re-fetches
// from what is now RAM. That is how the bootloader hands over to an image it
// has just received over the UART.
//
//   bank_switch = 0            bank_switch = 1
//   0x0000_0000  ROM           0x0000_0000  RAM
//   0x4000_0000  RAM           0x4000_0000  ROM
//
#define ROM_BASE          0x00000000
#define RAM_BASE          0x40000000

// Sizes come from cpu_ss's ROM_ADDR_WIDTH/RAM_ADDR_WIDTH (8 and 10 word
// address bits, see the defaults in hw/rtl/digital_ss.sv). Note that rom_ss
// only implements MEM_WORDS of the ROM window - sw/scripts/build_bootloader.sh
// checks the image against that, which is the tighter limit.
#define ROM_SIZE          0x00000400   // 1 KiB   (256 x 32b)
#define RAM_SIZE          0x00001000   // 4 KiB   (1024 x 32b)

// Bank switch control register. Anything in 0x6000_0000-0x7fff_ffff decodes to
// it, but cpu_ss only commits a write at this exact address (see
// bank_switch_write in hw/rtl/cpu_ss.sv). Reads return the current value in
// bit 0.
#define BANK_SWITCH_ADDR  0x7ffffffc

// --- Peripherals ----------------------------------------------------------
//
// Peripheral windows, matching the address decode in
// hw/rtl/interconnect_ss.sv. Each is 4 KiB except the external peripheral
// window. The 0x8000_0000 aperture is cpu_ss's: only addresses at or above it
// are turned into AHB transfers at all, everything below is ROM/RAM/bank
// switch. The offsets within the aperture are unchanged.
//
// SPI master and QSPI have no RTL behind them yet - those windows are driven
// by ahb_stub_slave, which returns an AHB error response on every access, so
// touching them raises IRQ_BUS_ERR.
#define AHB_BASE          0x80000000
#define AHB_UART_BASE     (AHB_BASE + 0x3000)
#define AHB_GPIO_BASE     (AHB_BASE + 0x4000)
#define AHB_QSPI_BASE     (AHB_BASE + 0x5000)
#define AHB_QSPI_MEM_BASE (AHB_BASE + 0x20000)
#define AHB_QSPI_MEM_SIZE 0x00800000
#define AHB_SPI_M_BASE    (AHB_BASE + 0x6000)
#define AHB_SPI_S_BASE    (AHB_BASE + 0x7000)
#define AHB_EXT_BASE      (AHB_BASE + 0x10000)

#endif // __CONFIG_H__
