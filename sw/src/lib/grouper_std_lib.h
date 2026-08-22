#ifndef __GROUPER_STD_LIB_H__
#define __GROUPER_STD_LIB_H__

// Umbrella header for the GrouperSoC firmware support library.
//
// There is no libc in this build (-ffreestanding -nostdlib), so this is it:
// formatted output, string and memory primitives, cycle counting, MMIO
// helpers, and a small self-checking test harness. Include this and you have
// all of them; the build passes -ffunction-sections/--gc-sections, so the
// parts a given image never calls cost it no ROM.
//
// Peripheral drivers are deliberately not here - they live in their own
// sw/src/<block>/ directories (uart/, spi_m/, ...) and are included directly.

#include "lib/gio.h"      // printf/snprintf/puts/getchar/hexdump, output sinks
#include "lib/gstr.h"     // memcpy/memset/strlen/strcmp/strtoul/...
#include "lib/gtime.h"    // g_cycles/g_delay_us
#include "lib/greg.h"     // g_rd32/g_wr32/g_poll
#include "lib/gtest.h"    // G_CHECK/G_CHECK_EQ/g_test_end/g_sim_exit

#endif // __GROUPER_STD_LIB_H__
