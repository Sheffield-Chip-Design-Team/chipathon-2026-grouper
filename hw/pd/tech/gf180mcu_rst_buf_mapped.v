// Global reset buffer - technology-mapped (gf180mcu_fd_sc_mcu7t5v0).
//
// LibreLane only: the std cell has no RTL model in the fusesoc flows, which
// use hw/pd/gl/gf180mcu_rst_buf_gl_model.v instead. See
// hw/pd/wrappers/gf180mcu_rst_buf_wrapper.sv for why this exists, and keep the
// u_buf instance name in step with grouper_chip_core.sdc.

/* verilator lint_off DECLFILENAME */
`ifdef FPGA
(* KEEP_HIERARCHY = "TRUE" *)
`endif
(* keep_hierarchy = "true" *)
module gf180mcu_rst_buf (
  input  wire rst_n_i,
  output wire rst_n_o
);

  (* keep = "true" *)
  gf180mcu_fd_sc_mcu7t5v0__buf_16 u_buf (
    .I (rst_n_i),
    .Z (rst_n_o)
  );

endmodule
