#include <stdint.h>

// A deliberately minimal, never-terminating firmware whose only observable
// behaviour is a counter in a fixed RAM word. It exists so that
// hw/tb/top/test_debug.py can prove a freeze-flavour BUS_LOCK actually stalls
// fetch/execute using nothing but wire-level debug commands: the host
// BUS_READs HEARTBEAT_ADDR twice while frozen and sees the same value, then
// resumes and sees it move. Reading picorv32's reg_pc over VPI would show the
// same thing, but only in an RTL simulation - this works against a gate-level
// netlist too, where there is no hierarchy left to peek into.
//
// Constraints this file is written to:
//
//   - It is linked for RAM (build_fw.sh --link ram, sw/boot/ram.ld) and loaded
//     by the ROM bootloader, because a ROM-linked image cannot be made small
//     enough: start.S installs the IRQ vector unconditionally, irq.c's fatal
//     handler calls printf, and that chain alone is ~950 bytes past the 1 KiB
//     rom_ss holds, whatever main() does.
//   - After the bootloader's bank switch RAM answers at 0x0000_0000, which is
//     also where ram.ld puts this image - so HEARTBEAT_ADDR below is the
//     address both this firmware and the debug host use, with no translation
//     on either side.
//   - It never returns and never prints. There is no TEST_RESULT line to wait
//     for; the testbench drives the whole test over the debug port and stops
//     the simulation itself. Anything that ends the program would end the
//     heartbeat with it.
//   - The counter is volatile and written every iteration so the compiler
//     cannot hoist it into a register: the whole point is the store, which is
//     what a debug-port read of RAM observes.

// Placed in the gap between the IRQ stack and the main stack. This image's
// .text/.data/.bss end around 0x7b0 and _eirq lands at 0x970, while the main
// stack grows *down* from _estack at 0x1000 - so the top of RAM is the one
// place this must not go, and anything at or below _eirq would be inside the
// image. 0x980 is just clear of _eirq with the stack's measured worst case
// (~250 bytes, i.e. down to about 0xf00) far above it. Kept in sync with
// HEARTBEAT_ADDR in hw/tb/top/test_debug.py; sw/build/firmware.map is the
// check if this image ever grows.
#define HEARTBEAT_ADDR 0x00000980

int main(void) {
    volatile uint32_t *heartbeat = (volatile uint32_t *) HEARTBEAT_ADDR;

    *heartbeat = 0;

    for (;;) {
        *heartbeat = *heartbeat + 1;
    }
}
