#ifndef __SOC_H__
#define __SOC_H__

// SoC-wide constants: the clock the design is run at, and the peripheral
// address map. Everything here describes the hardware, not any one driver -
// drivers include this rather than defining their own copies.

// Core clock. The UART baud divisor is computed against this, and gtime.h's
// delay helpers convert microseconds with it, so it must match the clock the
// SoC is actually run at. The top-level testbench cross-checks its own
// CLK_FREQ localparam against this value (hw/tb/top/grouper_soc_hello_tb.sv).
#define SYS_CLK_HZ  10000000

// Peripheral windows, matching the address decode in
// hw/rtl/ahb_interconnect_ss.sv. Each is 4 KiB except the external
// peripheral window.
//
// SPI master, SPI slave, QSPI and GPIO have no RTL behind them yet - those
// windows are driven by ahb_stub_slave, which returns an AHB error response
// on every access, so touching them raises IRQ_BUS_ERR.
#define AHB_ROM_BASE      0x00000000
#define AHB_RAM_BASE      0x00002000
#define AHB_UART_BASE     0x00003000
#define AHB_GPIO_BASE     0x00004000
#define AHB_QSPI_BASE     0x00005000
#define AHB_SPI_M_BASE    0x00006000
#define AHB_SPI_S_BASE    0x00007000
#define AHB_EXT_BASE      0x00010000

#endif // __SOC_H__
