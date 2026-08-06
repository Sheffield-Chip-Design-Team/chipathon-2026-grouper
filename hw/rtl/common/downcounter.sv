module downcounter #(
  parameter int WIDTH = 8
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic              load,
  input  logic              enable,
  input  logic [WIDTH-1:0]  load_value,

  output logic [WIDTH-1:0]  value,
  output logic              zero
);

  logic [WIDTH-1:0] next_value;

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n)
      value <= '0;
    else
      value <= next_value;

  always_comb begin
    if (load)
      next_value = load_value;
    else if (enable & ~zero)
      next_value = value - 'd1;
    else
      next_value = value;
  end

  assign zero = value == '0;

endmodule
