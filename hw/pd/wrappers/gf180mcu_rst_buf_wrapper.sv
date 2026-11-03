// Wrapper for the global reset buffer - the single, named root of the SoC
// reset tree.
//
// Synthesis flattens the design and SYNTH_AUTONAME is off, so the reset
// controller's output flop ends up with an anonymous _NNN_ name the SDC cannot
// find. An explicitly instantiated standard cell keeps its instance name
// through synthesis and resizing, which gives the PnR/signoff SDC a stable
// pin to hang the reset-tree exceptions on. repair_design still builds the
// fanout tree downstream of it.
//
// The gf180mcu_rst_buf instantiated here comes from whichever file the flow
// supplies - both define the same module name, so exactly one may be in a
// build:
//
//   hw/pd/tech/gf180mcu_rst_buf_mapped.v   LibreLane - the real std cell
//   hw/pd/gl/gf180mcu_rst_buf_gl_model.v   simulation/lint - a plain assign
//
// Instance names are load-bearing. grouper_soc_top instantiates this as
// u_glbl_rst_buf, and librelane/classic/grouper_chip_core.sdc matches the flattened
// pin *u_glbl_rst_buf.u_rst_buf.u_buf/Z - rename any of the three and the
// reset multicycle exception silently stops applying (the SDC warns).

`ifdef FPGA
(* KEEP_HIERARCHY = "TRUE" *)
`endif
(* keep_hierarchy = "true" *)
module gf180mcu_rst_buf_wrapper (
  input  logic rst_n_i,
  output logic rst_n_o
);

  gf180mcu_rst_buf u_rst_buf (
    .rst_n_i (rst_n_i),
    .rst_n_o (rst_n_o)
  );

endmodule
