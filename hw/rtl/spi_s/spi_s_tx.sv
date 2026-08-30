// SPI slave transmit path: TX FIFO, holding register and MISO shift register.
//
// The FIFO registers its read data, so a pop is only readable on the next
// clock. A one-entry holding register absorbs that latency, so a shift-register
// load never reads a same-cycle pop -- which is what made the SPI Master's
// first transmitted byte 0x00 (SPIM-ISSUE-010). Queue capacity is therefore
// FIFO_DEPTH + 1.

module spi_s_tx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  flush,

  // Wire side
  input  logic                  spi_ss,
  input  logic                  launch_edge,
  output logic                  miso,

  // Framing: assert while the data phase of a read is on the wire.
  input  logic                  send_en,

  // Byte source override, used by the debug path in place of the FIFO.
  input  logic                  ext_valid,
  input  logic [DATA_WIDTH-1:0] ext_data,

  // FIFO write side
  input  logic [DATA_WIDTH-1:0] wdata,
  input  logic                  write,
  output logic                  full,
  output logic                  empty,

  output logic                  busy,
  // In-transfer event: the host clocked a byte with nothing to send.
  output logic                  underrun
);

  logic [DATA_WIDTH-1:0] shift;
  logic [2:0]            bit_count;

  logic [DATA_WIDTH-1:0] fifo_rdata;
  logic                  fifo_read;
  logic                  fifo_read_r;
  logic [DATA_WIDTH-1:0] hold;
  logic                  hold_valid;
  logic                  load;
  logic                  src_valid;
  logic [DATA_WIDTH-1:0] src_data;

  small_sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_fifo (
    .clk   (clk),
    .rst_n (rst_n),
    .flush (flush),
    .wdata (wdata),
    .write (write && !full),
    .read  (fifo_read),
    .rdata (fifo_rdata),
    .full  (full),
    .empty (empty)
  );

  // Refill the holding register whenever it has room and the FIFO has a byte.
  assign fifo_read = !empty && !fifo_read_r && !hold_valid;

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      hold        <= '0;
      hold_valid  <= 1'b0;
      fifo_read_r <= 1'b0;
    end
    else if (flush) begin
      hold        <= '0;
      hold_valid  <= 1'b0;
      fifo_read_r <= 1'b0;
    end
    else begin
      fifo_read_r <= fifo_read;

      if (fifo_read_r) begin
        hold       <= fifo_rdata;
        hold_valid <= 1'b1;
      end

      if (load && !ext_valid)
        hold_valid <= 1'b0;
    end
  end

  // The debug path supplies bytes straight from a bus response, taking the
  // place of the FIFO on that path (GRPR-SPIS-032).
  assign src_valid = ext_valid ? 1'b1     : hold_valid;
  assign src_data  = ext_valid ? ext_data : hold;

  assign load = !spi_ss && send_en && !busy && src_valid;

  // Nothing to send when the host clocks the data phase.
  assign underrun = !spi_ss && send_en && !busy && !src_valid && launch_edge;

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      shift     <= '0;
      bit_count <= '0;
      busy      <= 1'b0;
    end
    else if (flush) begin
      shift     <= '0;
      bit_count <= '0;
      busy      <= 1'b0;
    end
    else begin
      if (load) begin
        shift     <= src_data;
        bit_count <= 3'd0;
        busy      <= 1'b1;
      end
      else if (!spi_ss && launch_edge && busy) begin
        shift     <= {shift[DATA_WIDTH-2:0], 1'b0};
        bit_count <= (bit_count == 3'd7) ? 3'd0 : (bit_count + 3'd1);
        if (bit_count == 3'd7)
          busy <= 1'b0;
      end
    end
  end

  assign miso = busy ? shift[DATA_WIDTH-1] : 1'b0;

endmodule
