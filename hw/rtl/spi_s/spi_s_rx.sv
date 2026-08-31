// SPI slave receive path: MOSI shift register and RX FIFO.
//
// Bytes are shifted in MSB-first on the mode-selected sampling edge and
// pushed to the FIFO when the framing layer says the byte is payload. The
// opcode and address phases are not payload, so the core gates the push
// rather than this block deciding for itself.

module spi_s_rx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4
) (
  input  logic                  clk,
  input  logic                  rst_n,

  input  logic                  flush,

  // Wire side
  input  logic                  spi_s_ss,
  input  logic                  spi_s_mosi,
  input  logic                  sample_edge,

  // Framing. push_en qualifies the completed byte as payload.
  input  logic                  push_en,
  output logic                  byte_done,
  output logic [DATA_WIDTH-1:0] byte_data,

  // FIFO read side
  input  logic                  read,
  output logic [DATA_WIDTH-1:0] rdata,
  output logic                  full,
  output logic                  empty,
  output logic [3:0]            level,

  // In-transfer event: a byte arrived with nowhere to put it.
  output logic                  overrun
);

  // The top bit is shifted out as each byte completes: byte_data takes it
  // from spi_s_mosi directly, so shift[7] itself is never read back.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [DATA_WIDTH-1:0] shift;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0]            bit_count;
  logic                  push;

  assign byte_data = {shift[DATA_WIDTH-2:0], spi_s_mosi};
  assign byte_done = !spi_s_ss && sample_edge && (bit_count == 3'd7);

  // Gated on !full here rather than inside the FIFO: small_sync_fifo holds
  // its write pointer when full but still executes memory[wptr] <= wdata, so
  // an unqualified push overwrites the oldest entry (SPIS-SPEC-013).
  assign push    = byte_done && push_en;
  assign overrun = push && full;

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      shift     <= '0;
      bit_count <= '0;
    end
    else if (flush) begin
      shift     <= '0;
      bit_count <= '0;
    end
    else if (spi_s_ss) begin
      bit_count <= '0;
    end
    else if (sample_edge) begin
      shift     <= {shift[DATA_WIDTH-2:0], spi_s_mosi};
      bit_count <= (bit_count == 3'd7) ? 3'd0 : (bit_count + 3'd1);
    end
  end

  small_sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_fifo (
    .clk   (clk),
    .rst_n (rst_n),
    .flush (flush),
    .wdata (byte_data),
    .write (push && !full),
    .read  (read),
    .rdata (rdata),
    .full  (full),
    .empty (empty)
  );

  // Occupancy for STATUS.RX_LEVEL; the FIFO exposes only full/empty.
  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n)
      level <= '0;
    else if (flush)
      level <= '0;
    else begin
      unique case ({(push && !full), read})
        2'b10:   level <= level + 4'd1;
        2'b01:   level <= level - 4'd1;
        default: level <= level;
      endcase
    end
  end

endmodule
