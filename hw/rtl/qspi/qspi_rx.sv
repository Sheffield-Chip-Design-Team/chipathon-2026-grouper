module qspi_rx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4,
  parameter int OVERSAMPLE = 8
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    uart_clk_en,

  // Control signals
  input  logic                    enable,
  input  logic                    rx_resync_en,
  output logic                    received,
  output logic                    rx_frame_error,
  output logic                    rx_break,

  // FIFO interfaces
  input  logic                    flush_rx_fifo,
  input  logic                    rx_read,
  output logic                    rx_full,
  output logic                    rx_empty,
  output logic [DATA_WIDTH-1:0]   rx_data,

  // UART interface
  input  logic                    uart_rx
);

  localparam int OVERSAMPLE_W = $clog2(OVERSAMPLE);
  localparam int SHIFT_CTR_W = $clog2(DATA_WIDTH);

  typedef enum logic [2:0] {
    ST_WAIT_START,
    ST_START_BIT,
    ST_DATA,
    ST_STOP_BIT,
    ST_BREAK
  } e_state;

  logic [OVERSAMPLE_W-1:0]  sample_ctr;
  logic                     inc_sample_ctr;
  logic                     reset_sample_ctr;
  logic                     resynced_sample_ctr;
  logic                     sample_bit;
  logic                     resync_window;
  logic                     shift_bit;
  logic                     fifo_write;
  logic [DATA_WIDTH-1:0]    fifo_wdata;
  logic                     shift_load;
  logic                     shift_ctr_zero;
  e_state                   state;
  e_state                   next_state;
  logic                     enable_r;
  logic                     rx_sync;
  logic                     rx_sync_r;
  logic                     break_detect;
  logic                     reset_break_detect;

  small_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (flush_rx_fifo),
    .wdata  (fifo_wdata),
    .write  (fifo_write),
    .read   (rx_read),
    .rdata  (rx_data),
    .full   (rx_full),
    .empty  (rx_empty)
  );

  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (1),
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (shift_bit),
    .load       ('0),
    .load_value ('0),
    .in         (rx_sync),
    .value_out  (fifo_wdata),
    .out        ()
  );

  downcounter #(
    .WIDTH(SHIFT_CTR_W)
  ) u_shift_ctr (
    .clk        (clk),
    .rst_n      (rst_n),
    .load       (shift_load),
    .enable     (shift_bit),
    .load_value (SHIFT_CTR_W'(DATA_WIDTH-1)),
    .value      (),
    .zero       (shift_ctr_zero)
  );

  sync u_sync(
    .clk    (clk),
    .rst_n  (rst_n),
    .data_i (uart_rx),
    .data_o (rx_sync)
  );

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      enable_r <= '0;
      rx_sync_r <= '1;
      break_detect <= '0;
    end else if (uart_clk_en) begin
      enable_r <= enable;
      rx_sync_r <= rx_sync;
      if (reset_break_detect)
        break_detect <= ~rx_sync;
      else
        break_detect <= break_detect && ~rx_sync;
    end

  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) begin
      sample_ctr <= '0;
      resynced_sample_ctr <= '0;
      state <= ST_WAIT_START;
    end else if (enable && uart_clk_en) begin
      if (~enable_r) begin // Go to idle state after being enabled
        sample_ctr <= '0;
        resynced_sample_ctr <= '0;
        state <= ST_WAIT_START;
      end else begin
        state <= next_state;
        if (reset_sample_ctr) begin
          sample_ctr <= 'd1;
          resynced_sample_ctr <= resync_window;
        end else if (inc_sample_ctr) begin
          sample_ctr <= sample_ctr + 'd1; // Intentional overflow
          resynced_sample_ctr <= resynced_sample_ctr && resync_window; // Prevent multiple resyncs
        end
      end
    end

  assign sample_bit = sample_ctr == OVERSAMPLE_W'(OVERSAMPLE/2);
  // Allow resync for -1, 0, 1
  assign resync_window = sample_ctr == '1 || sample_ctr == '0 || sample_ctr == 'd1;

  always_comb begin
    next_state = state;
    received = '0;
    rx_frame_error = '0;
    rx_break = state == ST_BREAK;
    fifo_write = '0;
    shift_load = '0;
    shift_bit = '0;
    inc_sample_ctr = '0;
    reset_sample_ctr = '0;
    reset_break_detect = '0;

    if (enable && uart_clk_en) begin
      unique case (state)
        ST_WAIT_START: if (rx_sync_r && ~rx_sync) begin // 1 -> 0 (start bit)
          reset_sample_ctr = '1;
          reset_break_detect = '1;
          shift_load = '1;
          next_state = ST_START_BIT;
        end
        ST_START_BIT: begin
          inc_sample_ctr = '1;
          if (sample_bit) begin
            if (~rx_sync) begin
              next_state = ST_DATA;
            end else begin // Start bit is not 0
              rx_frame_error = '1;
              next_state = ST_WAIT_START;
            end
          end
        end
        ST_DATA: begin
          inc_sample_ctr = '1;
          if (resync_window && rx_resync_en && ~resynced_sample_ctr) begin
            reset_sample_ctr = rx_sync_r != rx_sync; // Resync on an edge
          end
          if (sample_bit) begin
            shift_bit = '1;
            if (shift_ctr_zero) begin
              next_state = ST_STOP_BIT;
            end
          end
        end
        ST_STOP_BIT: begin
          inc_sample_ctr = '1;
          if (resync_window && rx_resync_en && ~resynced_sample_ctr) begin
            reset_sample_ctr = rx_sync_r != rx_sync; // Resync on an edge
          end
          if (sample_bit) begin
            next_state = ST_WAIT_START;
            if (rx_sync) begin
              fifo_write = '1;
              received = '1;
            end else begin // Stop bit is not 1
              rx_frame_error = '1;
              if (break_detect) begin
                next_state = ST_BREAK;
                rx_break = '1;
              end
            end
          end
        end
        ST_BREAK: if (~break_detect) begin
          rx_break = '0;
          next_state = ST_WAIT_START;
        end
        default: next_state = ST_WAIT_START;
      endcase
    end
  end

endmodule
