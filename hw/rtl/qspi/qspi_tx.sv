module qspi_tx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4,
  parameter int OVERSAMPLE = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    uart_clk_en,

  // Control signals
  input  logic                    enable,
  input  logic                    tx_break,
  output logic                    tx_active,

  // FIFO interfaces
  input  logic                    flush_tx_fifo,
  input  logic [DATA_WIDTH-1:0]   tx_data,
  input  logic                    tx_write,
  output logic                    tx_full,
  output logic                    tx_empty,

  // UART interface
  output logic                    uart_tx
);

  localparam int OVERSAMPLE_W = $clog2(OVERSAMPLE);
  localparam int SHIFT_CTR_W = $clog2(DATA_WIDTH);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_START_BIT,
    ST_DATA,
    ST_STOP_BIT
  } e_state;

  logic [OVERSAMPLE_W-1:0]  sample_ctr;
  logic                     shift_bit;
  logic                     fifo_read;
  logic [DATA_WIDTH-1:0]    fifo_rdata;
  logic                     shift_load;
  logic                     shift_out;
  logic                     shift_ctr_zero;
  e_state                   state;
  e_state                   next_state;
  logic                     next_tx;
  logic                     enable_r;

  small_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (flush_tx_fifo),
    .wdata  (tx_data),
    .write  (tx_write),
    .read   (fifo_read),
    .rdata  (fifo_rdata),
    .full   (tx_full),
    .empty  (tx_empty)
  );

  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (1),
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (enable && shift_bit),
    .load       (shift_load),
    .load_value (fifo_rdata),
    .in         (1'b0),
    .value_out  (),
    .out        (shift_out)
  );

  downcounter #(
    .WIDTH(SHIFT_CTR_W)
  ) u_shift_ctr (
    .clk        (clk),
    .rst_n      (rst_n),
    .load       (shift_load),
    .enable     (enable && shift_bit),
    .load_value (SHIFT_CTR_W'(DATA_WIDTH-1)),
    .value      (),
    .zero       (shift_ctr_zero)
  );

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      enable_r <= '0;
      uart_tx <= '1;
    end else if (uart_clk_en) begin
      enable_r <= enable;
      uart_tx <= enable ? next_tx : '1;
    end

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      sample_ctr <= '0;
      state <= ST_IDLE;
    end else if (enable && uart_clk_en) begin
      if (~enable_r) begin // Go to idle state after being enabled
        sample_ctr <= '0;
        state <= ST_IDLE;
      end else begin
        sample_ctr <= sample_ctr + 'd1; // Intentional overflow
        state <= next_state;
      end
    end

  assign shift_bit = uart_clk_en && sample_ctr == '0;

  assign tx_active = enable && state != ST_IDLE;

  // Split into two processes so Verilator can order them acyclically: this
  // one drives shift_load (u_shift_reg.load) and must not read shift_out
  // (u_shift_reg.out, combinational since REGISTERED_OUT=0) - otherwise it
  // and the block below form an UNOPTFLAT self-loop through the submodule
  // (this block -> shift_load -> u_shift_reg -> shift_out -> this block).
  always_comb begin
    next_state = state;
    fifo_read = '0;
    shift_load = '0;

    if (enable && shift_bit) begin
      unique case (state)
        ST_IDLE: begin
          if (!tx_break && !tx_empty && !flush_tx_fifo && uart_tx) begin // 1 cycle high after break before start bit
            next_state = ST_START_BIT;
            fifo_read = '1;
          end
        end
        ST_START_BIT: begin
          next_state = ST_DATA;
          shift_load = '1;
        end
        ST_DATA: begin
          if (shift_ctr_zero) begin
            next_state = ST_STOP_BIT;
          end
        end
        ST_STOP_BIT: begin
          next_state = ST_IDLE;
          if (!tx_break && !tx_empty && !flush_tx_fifo) begin
            next_state = ST_START_BIT;
            fifo_read = '1;
          end
        end
        default: next_state = ST_IDLE;
      endcase
    end
  end

  // Reads shift_out (fine here - this block never drives shift_load).
  always_comb begin
    next_tx = uart_tx;

    if (enable && shift_bit) begin
      unique case (state)
        ST_IDLE: begin
          next_tx = '1; // Idle
          if (tx_break) begin
            next_tx = '0; // Break
          end else if (!tx_empty && !flush_tx_fifo && uart_tx) begin // 1 cycle high after break before start bit
            next_tx = '0; // Start bit
          end
        end
        ST_START_BIT: begin
          next_tx = shift_out; // Shift reg output not registered, so will read the first bit we are loading
        end
        ST_DATA: begin
          next_tx = shift_out;
          if (shift_ctr_zero) begin
            next_tx = '1; // Stop bit
          end
        end
        ST_STOP_BIT: begin
          if (tx_break) begin
            next_tx = '0; // Break
          end else if (!tx_empty && !flush_tx_fifo) begin
            next_tx = '0; // Start bit
          end
        end
        default: ;
      endcase
    end
  end


endmodule
