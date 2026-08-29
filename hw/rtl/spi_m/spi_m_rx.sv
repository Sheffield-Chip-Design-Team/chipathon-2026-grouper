// SPI master receive path.
//
// Sampling is driven entirely by the TX sequencer: sck_sample pulses once per
// SCK period on the CPOL/CPHA-correct edge, and rx_active is only true during
// a read data phase. There is no independent FSM here -- the previous
// free-running one double-sampled every bit and captured the command, address
// and dummy phases as data (SPIM-ISSUE-007/-008).

module spi_m_rx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    rx_active,   // data phase AND CMD.DIR == read
  input  logic                    sck_sample,  // one pulse per SCK period

  output logic                    received,
  output logic                    rx_overrun,

  input  logic                    flush_rx_fifo,
  input  logic                    rx_read,
  output logic                    rx_full,
  output logic                    rx_empty,
  output logic [DATA_WIDTH-1:0]   rx_data,

  input  logic                    spi_miso
);

  localparam int BIT_CTR_W = $clog2(DATA_WIDTH) + 1;

  logic [BIT_CTR_W-1:0]  bit_count;
  logic                  last_bit;
  logic                  shift_bit;
  logic                  fifo_write;
  logic [DATA_WIDTH-1:0] fifo_wdata;

  assign shift_bit = rx_active && sck_sample;
  assign last_bit  = (bit_count == BIT_CTR_W'(DATA_WIDTH - 1));

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

  // REGISTERED_OUT=0 means value_out already includes the bit being shifted
  // in this cycle, so the byte can be written to the FIFO on the same edge
  // that captures its last bit.
  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (0),
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (shift_bit),
    .load       (1'b0),
    .load_value ('0),
    .in         (spi_miso),
    .value_out  (fifo_wdata),
    /* verilator lint_off PINCONNECTEMPTY */
    .out        ()
    /* verilator lint_on PINCONNECTEMPTY */
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      bit_count <= '0;
    else if (!rx_active)
      bit_count <= '0;
    else if (shift_bit)
      bit_count <= last_bit ? '0 : (bit_count + 1'b1);
  end

  // A byte is complete on the sampling edge that captures bit 0.
  assign fifo_write = shift_bit && last_bit && !rx_full;
  assign received   = shift_bit && last_bit;

  // In-transfer overrun: a byte arrived with nowhere to put it.
  assign rx_overrun = shift_bit && last_bit && rx_full;

endmodule
