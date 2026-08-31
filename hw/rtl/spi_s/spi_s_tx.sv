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

  // Discard anything still queued or in flight, at a frame boundary. Unlike
  // `flush` (CTRL.SOFT_RESET, a host-commanded reset of the whole block)
  // this is asserted per frame by the debug transport, which owns the queue
  // only for the length of one command: a response is meaningless once its
  // frame has ended, and a byte left behind would be handed to the *next*
  // frame as if it belonged there, offsetting that whole response by a byte.
  // The legacy FIFO path deliberately does not assert this - TXDATA written
  // between frames is supposed to survive until the host clocks it out.
  input  logic                  frame_flush,

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
  logic                  reload;
  logic                  src_valid;
  logic [DATA_WIDTH-1:0] src_data;

  small_sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_fifo (
    .clk   (clk),
    .rst_n (rst_n),
    .flush (flush || frame_flush),
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
    else if (flush || frame_flush) begin
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

      // Both arms consume the holding register, so both have to free it -
      // see the note above `reload`. Missing it here would leave hold_valid
      // set on a byte already shifted out, so fifo_read never refills and
      // the rest of the burst repeats that byte.
      if ((load || reload) && !ext_valid)
        hold_valid <= 1'b0;
    end
  end

  // The debug path supplies bytes straight from a bus response, taking the
  // place of the FIFO on that path (GRPR-SPIS-032).
  assign src_valid = ext_valid ? 1'b1     : hold_valid;
  assign src_data  = ext_valid ? ext_data : hold;

  // A byte ends on the launch edge that retires its last bit. `reload` is
  // that edge with another byte already waiting, and it loads on the spot
  // rather than letting busy drop and picking the next byte up a cycle later.
  //
  // That extra cycle was a real off-by-one on the wire. A mid-byte bit moves
  // to MISO *on* its launch edge, one clock before the master's sample edge;
  // a byte boundary handled in two steps (launch edge clears busy, next clock
  // loads) put the new byte's MSB on MISO one clock later than that, i.e.
  // level with the sample edge instead of ahead of it. The master therefore
  // still saw the previous bit and every byte after the first came back with
  // bit 7 dropped - 0xAD read back as 0x2D. Only the first byte of a frame
  // was right, which is why a payload with bit 7 clear in every byte (say
  // 0x12345678) could not see this at all.
  //
  // `load` keeps its original meaning: the first byte of a frame, when
  // nothing is shifting yet. Both arms feed the same shift/bit_count/busy
  // update below.
  assign load   = !spi_ss && send_en && !busy && src_valid;
  assign reload = !spi_ss && send_en && busy && src_valid &&
                  launch_edge && (bit_count == 3'd7);

  // Nothing to send when the host clocks the data phase.
  assign underrun = !spi_ss && send_en && !busy && !src_valid && launch_edge;

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      shift     <= '0;
      bit_count <= '0;
      busy      <= 1'b0;
    end
    else if (flush || frame_flush) begin
      shift     <= '0;
      bit_count <= '0;
      busy      <= 1'b0;
    end
    else begin
      if (load || reload) begin
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
