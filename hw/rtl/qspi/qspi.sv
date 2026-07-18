module qspi #(
  parameter int CLK_DIV_BITS = 10,
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // Control signals
  input  logic                    enable,
  input  logic [CLK_DIV_BITS-1:0] clk_div,
  input  logic                    tx_en,
  input  logic                    rx_en,
  input  logic                    rx_resync_en,
  input  logic                    tx_break,
  output logic                    tx_active,
  output logic                    received,
  output logic                    rx_frame_error,
  output logic                    rx_break,

  // FIFO interfaces
  input  logic                    flush_tx_fifo,
  input  logic [DATA_WIDTH-1:0]   tx_data,
  input  logic                    tx_write,
  output logic                    tx_full,
  output logic                    tx_empty,

  input  logic                    flush_rx_fifo,
  input  logic                    rx_read,
  output logic                    rx_full,
  output logic                    rx_empty,
  output logic [DATA_WIDTH-1:0]   rx_data,

  // UART interface
  output logic                    uart_tx,
  input  logic                    uart_rx
);
  localparam int OVERSAMPLE = 8; // Must be power of 2

  logic uart_clk_en;

  qspi_clk_div #(
    .CLK_DIV_BITS(CLK_DIV_BITS)
  ) u_clk_div (
    .clk      (clk),
    .rst_n    (rst_n),
    .enable   (enable),
    .clk_div  (clk_div),
    .zero     (uart_clk_en)
  );

  qspi_tx #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH),
    .OVERSAMPLE (OVERSAMPLE)
  ) u_uart_tx (
    .clk            (clk),
    .rst_n          (rst_n),
    .uart_clk_en    (uart_clk_en),
    .enable         (enable && tx_en),
    .tx_break       (tx_break),
    .tx_active      (tx_active),
    .flush_tx_fifo  (flush_tx_fifo),
    .tx_data        (tx_data),
    .tx_write       (tx_write),
    .tx_full        (tx_full),
    .tx_empty       (tx_empty),
    .uart_tx        (uart_tx)
  );

  qspi_rx #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH),
    .OVERSAMPLE (OVERSAMPLE)
  ) u_uart_rx (
    .clk            (clk),
    .rst_n          (rst_n),
    .uart_clk_en    (uart_clk_en),
    .enable         (enable && rx_en),
    .rx_resync_en   (rx_resync_en),
    .received       (received),
    .rx_frame_error (rx_frame_error),
    .rx_break       (rx_break),
    .flush_rx_fifo  (flush_rx_fifo),
    .rx_read        (rx_read),
    .rx_full        (rx_full),
    .rx_empty       (rx_empty),
    .rx_data        (rx_data),
    .uart_rx        (uart_rx)
  );

endmodule
