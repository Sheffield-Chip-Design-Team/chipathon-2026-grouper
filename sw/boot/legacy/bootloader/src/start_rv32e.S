.section .reset.text, "ax"
.global reset_vec

reset_vec:
    .cfi_startproc
    .cfi_undefined ra
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, _estack
    add s0, sp, zero
    jal zero, main
    .cfi_endproc
    // .end // Do not end the file here
