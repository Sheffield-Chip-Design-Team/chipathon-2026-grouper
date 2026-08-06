module shift_reg #(
  parameter int WIDTH           = 16,
  parameter bit LSB_FIRST       = 1,
  parameter bit REGISTERED_OUT  = 1
) (
  input  logic              clk,
  input  logic              rst_n,

  input  logic              shift,
  input  logic              load,
  input  logic [WIDTH-1:0]  load_value,
  input  logic              in,
  
  output logic [WIDTH-1:0]  value_out,
  output logic              out
);

  logic [WIDTH-1:0] next_value;
  logic [WIDTH-1:0] value;

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n)
      value <= '0;
    else if (load || shift)
      value <= next_value;

  always_comb
    if (load) begin
      next_value = load_value;
    end else if (shift) begin
      if (LSB_FIRST)
        next_value = {in, value[WIDTH-1:1]};
      else
        next_value = {value[WIDTH-2:0], in};
    end else begin
      next_value = value;
    end

  assign value_out = REGISTERED_OUT ? value : next_value;

  generate
    if (LSB_FIRST) begin : gen_lsb_first
      assign out = REGISTERED_OUT ? value[0] : next_value[0];
    end else begin : gen_msb_first
      assign out = REGISTERED_OUT ? value[WIDTH-1] : next_value[WIDTH-1];
    end
  endgenerate

endmodule
