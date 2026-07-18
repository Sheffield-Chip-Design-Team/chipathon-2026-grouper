module clk_gate (
  input  logic clk_i,
  input  logic enable,
  output logic clk_o
);

`ifdef FPGA

  BUFGCE u_clk_buf (
		.I (clk_i),
		.CE (enable),
		.O (clk_o)
	);

`else

  logic latched_en;

  // Either replace this with a FPGA primative
  // Or enable inferred clock gates

  // latched_en cannot change while clock is high
  always_latch begin
    if (~clk_i) 
      latched_en = enable;
  end

  assign clk_o = clk_i & latched_en;

`endif

endmodule
