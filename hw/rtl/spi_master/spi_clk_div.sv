module uart_clk_div #(
  parameter int CLK_DIV_BITS = 10
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    enable,
  input  logic [CLK_DIV_BITS-1:0] clk_div,

  output logic                    zero
);

  logic                    enable_r;
  logic [CLK_DIV_BITS-1:0] ctr;

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      enable_r <= '0;
    end else begin
      enable_r <= enable;
    end

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n)
      ctr <= '0;
    else if (enable)
      ctr <= (zero || ~enable_r) ? clk_div : (ctr - 'd1);

  assign zero = ctr == '0;

endmodule
