module clk_div #(
  parameter int unsigned N = 12_000_000 / 10 // Must be even
) (
  input logic clk_i,
  input logic rst_n,
  output logic phase_zero, // Goes high the cycle before cnt wraps and clk_o transitions from 1 -> 0
  output logic clk_o
);
  localparam int unsigned M = N / 2; // We get a /2 from the output being toggled
  localparam int CTR_WIDTH = $clog2(M);

  generate
    if ((N % 2 != 0) || N < 2) begin : gen_error
      $error("clk_div : N must be even and >= 2");
    end else if (N == 2) begin : gen_div_2
      always_ff @(posedge clk_i, negedge rst_n)
        if (~rst_n)
          clk_o     <= '0;
        else
          clk_o       <= ~clk_o;

      assign phase_zero = clk_o; // The cycle before it changes to 0
  
    end else begin : gen_div_n
      logic [CTR_WIDTH-1:0] cnt;
    
      always_ff @(posedge clk_i, negedge rst_n)
        if (~rst_n) begin
          cnt   <= CTR_WIDTH'(M-1);
          clk_o <= '0;
        end else
          if (cnt == '0) begin
            cnt   <= '0;
            clk_o <= ~clk_o;
          end else begin
            cnt <= cnt - 1;
          end

      assign phase_zero = clk_o && (cnt == '0); // The cycle before it changes to 0
    
      initial
        cnt = CTR_WIDTH'(M-1);

    end
  endgenerate

  initial
    clk_o = '0;

endmodule
