// Safe reset controller
// The counter allows for multi-cycle path constraints on the reset, to avoid timing issues
// Does the following: (Wait 2**CTR_WIDTH) cycles between state transitions
//  1. Reset Asserted, Clock Disabled
//  2. Reset Asserted, Clock Enabled
//  3. Reset Asserted, Clock Disabled
//  4. Reset Deasserted, Clock Disabled
//  5. Reset Deasserted, Clock Enabled

module reset_controller #(
  parameter int unsigned CTR_WIDTH = 3
) (
  input  logic clk_i,
  input  logic rst_n_i,
  input  logic rst_request,
  output logic clk_o,
  output logic rst_n_o
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_RST_EN_CLK_DIS_1,
    ST_RST_EN_CLK_EN,
    ST_RST_EN_CLK_DIS_2,
    ST_RST_DIS_CLK_DIS,
    ST_RUN
  } e_state;

  logic                 rst_n_sync;
  logic [CTR_WIDTH-1:0] ctr;
  e_state               next_state;
  e_state               state;
  logic                 clk_en;

  // Generate an async assert, sync release reset for controller logic
  sync #(
    .RESET_VALUE(1'b0)
  ) u_sync (
    .clk    (clk_i),
    .rst_n  (rst_n_i),
    .data_i (1'b1),
    .data_o (rst_n_sync)
  );

  clk_gate u_clk_gate (
    .clk_i  (clk_i),
    .enable (clk_en),
    .clk_o  (clk_o)
  );

  always_ff @(posedge clk_i, negedge rst_n_sync)
    if (rst_n_sync == 1'b0) begin
      state   <= ST_IDLE;
      rst_n_o <= 1'b0;
      clk_en  <= 1'b0;
      ctr     <= '0;
    end else begin
      state   <= next_state;
      rst_n_o <= (next_state == ST_RST_DIS_CLK_DIS) || (next_state == ST_RUN);
      clk_en  <= (next_state == ST_RST_EN_CLK_EN) || (next_state == ST_RUN);
      
      // Hold the counter at zero in ST_RUN so a rst_request is seen on the
      // first cycle it is raised
      if (next_state == ST_RUN) begin
        ctr <= '0;
      end else begin
        ctr <= CTR_WIDTH'(ctr + 'd1);
      end
    end

  always_comb begin
    next_state = state;
    if (ctr == '0) begin
      case (state)
        ST_IDLE:              next_state = ST_RST_EN_CLK_DIS_1;
        ST_RST_EN_CLK_DIS_1:  next_state = ST_RST_EN_CLK_EN;
        ST_RST_EN_CLK_EN:     next_state = ST_RST_EN_CLK_DIS_2;
        ST_RST_EN_CLK_DIS_2:  next_state = ST_RST_DIS_CLK_DIS;
        ST_RST_DIS_CLK_DIS:   next_state = ST_RUN;
        ST_RUN:               if (rst_request == 1'b1) next_state = ST_IDLE;
        default:              next_state = ST_IDLE;
      endcase
    end
  end

endmodule
