module pulse_sync #(
  parameter int   DEPTH = 2
) (
  input  logic clk_i,
  input  logic rst_i_n,
  input  logic data_i,
  
  input  logic rst_o_n,
  input  logic clk_o,
  output logic data_o
);

  logic data_i_d;
  logic toggle_i;

  always_ff @(posedge clk_i, negedge rst_i_n)
    if (~rst_i_n) begin
      data_i_d <= '0;
      toggle_i <= '0;
    end else begin
      data_i_d <= data_i;
      if (data_i & ~data_i_d)
        toggle_i <= ~toggle_i;
    end

  logic toggle_o;
  logic toggle_o_d;

  sync #(
    .DEPTH  (DEPTH)
  ) u_sync (
    .clk    (clk_o),
    .rst_n  (rst_o_n),
    .data_i (toggle_i),
    .data_o (toggle_o)
  );

  always_ff @(posedge clk_o, negedge rst_o_n)
    if (~rst_o_n)
      toggle_o_d <= '0;
    else
      toggle_o_d <= toggle_o;

  initial begin
    // For FPGA
    toggle_i    = '0;
    toggle_o_d  = '0;
  end

  assign data_o = toggle_o ^ toggle_o_d;

endmodule
