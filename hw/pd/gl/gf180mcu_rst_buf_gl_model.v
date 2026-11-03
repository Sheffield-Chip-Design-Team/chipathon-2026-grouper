// Global reset buffer - simulation model of hw/pd/tech/gf180mcu_rst_buf_mapped.v.
//
// Same module name and ports as the mapped cell, functionally identical
// (Z = I), no timing. Used by every fusesoc flow; LibreLane takes the mapped
// file instead. See hw/pd/wrappers/gf180mcu_rst_buf_wrapper.sv.

/* verilator lint_off DECLFILENAME */
`ifdef FPGA
(* KEEP_HIERARCHY = "TRUE" *)
`endif
(* keep_hierarchy = "true" *)
module gf180mcu_rst_buf (
  input  wire rst_n_i,
  output wire rst_n_o
);

  assign rst_n_o = rst_n_i;

endmodule
