module clk_out #(
  parameter bit INVERT = 1'b0
) (
  input logic clk_i,
  output logic clk_o
);

`ifdef FPGA

  // https://www.edaboard.com/threads/clock-output-from-fpga.206190/
  ODDR2 #(
    .DDR_ALIGNMENT("NONE")
  ) u_oddr2 (
    .D0(INVERT ? 1'b0 : 1'b1),
    .D1(INVERT ? 1'b1 : 1'b0),
    .C0(clk_i),
    .C1(~clk_i),
    .CE(1'b1),
    .R(1'b0),
    .S(1'b0),
    .Q(clk_o)
  );

`else

  assign clk_o = INVERT ? ~clk_i : clk_i;

`endif

endmodule
