`ifdef FPGA
(* KEEP_HIERARCHY = "TRUE" *)
`endif
module sync #(
  parameter int   DEPTH = 2,
  parameter logic RESET_VALUE = '0
) (
  input  logic clk,
  input  logic rst_n,
  input  logic data_i,
  output logic data_o
);

`ifdef FPGA
(* ASYNC_REG="TRUE" *)
`endif
  logic [DEPTH-1:0] data_r;

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n)
      data_r <= {DEPTH{RESET_VALUE}};
    else
      data_r <= {data_r[DEPTH-2:0], data_i};

`ifdef FPGA
  initial
    data_r = '0; // For FPGA
`endif

  assign data_o = data_r[DEPTH-1];

endmodule
