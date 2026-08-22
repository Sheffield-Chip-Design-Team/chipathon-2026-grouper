.section .reset.text, "ax"
.global reset_vec

reset_vec:
    .cfi_startproc
    .cfi_undefined ra
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    // main() is built stack-free (see sw/boot/bootloader.c), so sp is only a
    // safety net for anything that reintroduces a frame - which the build
    // would reject first. No frame pointer: build_bootloader.sh passes
    // -ffixed-s0, so leave s0 alone rather than pointing it here.
    la sp, _estack
    jal zero, main
    .cfi_endproc
    // .end // Do not end the file here
