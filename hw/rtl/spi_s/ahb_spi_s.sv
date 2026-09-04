// AHB-Lite SPI slave: register file and bus interface.
//
// The wire-facing logic lives in spi_s_core (framing FSM, RX/TX paths, debug
// transport); this module owns the register map and the AHB handshake.
//
// Register map (GRPR-SPIS-001):
//   0x00 CTRL        R/W   ENABLE[0] SOFT_RESET[1] CPHA[2] CPOL[3]
//                          (bit 4 reserved -- see GRPR-SPIS-030, withdrawn)
//   0x04 STATUS      RO    BUSY[0] RX_VALID[1] TX_READY[2] DEBUG_BUSY[3]
//                          RX_EMPTY[4] RX_FULL[5] TX_EMPTY[6] TX_FULL[7]
//                          RX_LEVEL[11:8]
//   0x08 TXDATA      WO    TX FIFO push, 1-4 bytes by HSIZE
//   0x0C RXDATA      RO    RX FIFO pop,  1-4 bytes by HSIZE
//   0x10 IRQ_STATUS  W1C   RX_VALID[0] UNDERRUN[1] OVERRUN[2]
//                          UNDERFLOW[4] OVERFLOW[5]
//   0x14 IRQ_EN      R/W   same bit positions as IRQ_STATUS
//
// UNDERRUN/OVERRUN are the in-transfer (wire-side) FIFO events, caused by the
// external host outrunning firmware. UNDERFLOW/OVERFLOW are the AHB access
// errors, caused by firmware mis-sizing its own access. Keeping them apart is
// what lets a debugger tell which side of the block went wrong.

module ahb_spi_s #(
  parameter int ADDR_WIDTH    = 32,
  parameter int DATA_WIDTH    = 32,
  parameter int FIFO_DEPTH    = 4,   // supports up to 8 entries (GRPR-SPIS-023 / -024).
  parameter int DEBUG_PORT_EN = 0
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals
  /* verilator lint_off UNUSEDSIGNAL */
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,
  /* verilator lint_on UNUSEDSIGNAL */

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL,

  // SPI interface
  input logic                   spi_s_ss,
  input logic                   spi_s_sck,
  input logic                   spi_s_mosi,
  output logic                  spi_s_miso,

  // Debug port. 
  // This block is a debug *transport*: it frames SPI commands
  // into requests and never masters a bus itself. 
  output logic                  dbg_req_valid,
  input  logic                  dbg_req_ready,
  output logic [3:0]            dbg_req_cmd,
  output logic [31:0]           dbg_req_addr,
  output logic [31:0]           dbg_req_wdata,
  output logic [1:0]            dbg_req_size,
  input  logic                  dbg_rsp_valid,
  output logic                  dbg_rsp_ready,
  input  logic [31:0]           dbg_rsp_rdata,
  input  logic                  dbg_rsp_err,

  output logic                  irq
);
  import ahb3lite_pkg::*; // AHBlite packages

  localparam int       SPI_S_DATA_W = 8;

  // Six registers now, so the decode is HADDR[4:2] rather than the HADDR[3:2]
  // that four needed. Offsets above IRQ_EN are reserved and error, matching
  // ADDR_SPI_M_MAX in the SPI Master.
  localparam bit [2:0] ADDR_CTRL      = 3'd0;
  localparam bit [2:0] ADDR_STATUS    = 3'd1;
  localparam bit [2:0] ADDR_TXDATA    = 3'd2;
  localparam bit [2:0] ADDR_RXDATA    = 3'd3;
  localparam bit [2:0] ADDR_IRQ_STS   = 3'd4;
  localparam bit [2:0] ADDR_IRQ_EN    = 3'd5;
  localparam bit [2:0] ADDR_SPI_S_MAX = ADDR_IRQ_EN;

  // Control registers
  logic                     ctrl_enable;
  logic                     ctrl_soft_reset;
  logic                     ctrl_cpha;
  logic                     ctrl_cpol;

  // IRQ_STATUS / IRQ_EN. Bit 3 is reserved: the SPI Master's CFG_ERR has no
  // analogue here, and leaving the position vacant keeps the two maps aligned
  // so a shared driver header can use one set of masks.
  logic int_rx_valid, int_underrun, int_overrun, int_underflow, int_overflow;
  logic ie_rx_valid,  ie_underrun,  ie_overrun,  ie_underflow,  ie_overflow;

  // AHB pipeline
  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;
  logic [2:0]                 word_address;
  logic [2:0]                 word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;
  logic                       invalid_access;
  logic                       err_req;
  logic                       err_second_cycle;

  // Core interface
  logic [SPI_S_DATA_W-1:0] rx_rdata;
  logic                    rx_read;
  logic                    rx_full;
  logic                    rx_empty;
  logic [3:0]              rx_level;

  logic [SPI_S_DATA_W-1:0] tx_wdata;
  logic                    tx_write;
  logic                    tx_full;
  logic                    tx_empty;

  logic                    core_busy;
  logic                    rx_overrun;
  logic                    tx_underrun;
  logic                    dbg_err_evt;
  logic                    rx_byte_pushed;
  logic                    fifo_flush;

  // Lane machine
  logic [3:0]              lane_pending;
  logic [1:0]              lane_index;
  logic                    lane_is_read;
  logic                    lane_stall;
  logic [DATA_WIDTH-1:0]   lane_wdata;
  logic [DATA_WIDTH-1:0]   rx_assemble;
  logic [1:0]              rx_lane_index_r;
  logic                    rx_read_r;
  logic                    data_write;
  logic                    data_read;
  logic [3:0]              lane_next;
  logic                    lane_start_w;
  logic                    lane_start_r;
  logic                    lane_rd_active;
  logic                    lane_underflow_evt;
  logic                    lane_overflow_evt;

//------------------------------------------------------
// AHB address phase decode
//------------------------------------------------------

  assign access      = HREADYIN && HSEL && (HTRANS == HTRANS_NONSEQ || HTRANS == HTRANS_SEQ);
  assign read_enable = access && ~HWRITE;

  assign word_address = access ? HADDR[4:2] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

//------------------------------------------------------
// AHB pipeline register
//------------------------------------------------------

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      write_enable   <= 1'b0;
      read_enable_r  <= 1'b0;
      word_address_r <= '0;
      byte_select_r  <= '0;
    end
    else if (lane_stall) begin
      // Hold the data phase. HREADYOUT is low, so the master is still
      // presenting this transfer and must not have its control signals
      // overwritten by the address phase of the next one. Everything below is
      // qualified by these registers, so letting them advance under a stall
      // would retire the access against the wrong register, or retire it twice.
      write_enable   <= write_enable;
      read_enable_r  <= read_enable_r;
      word_address_r <= word_address_r;
      byte_select_r  <= byte_select_r;
    end
    else begin
      write_enable   <= access && HWRITE;
      read_enable_r  <= read_enable;
      word_address_r <= word_address;
      byte_select_r  <= byte_select;
    end
  end

  assign data_write = write_enable  && (word_address_r == ADDR_TXDATA);
  assign data_read  = read_enable_r && (word_address_r == ADDR_RXDATA);

//------------------------------------------------------
// Multi-byte TXDATA / RXDATA lane machine (GRPR-SPIS-025 .. -027)
//------------------------------------------------------
// One byte per asserted HSIZE lane, low lane first. The FIFO takes one access
// per cycle, so the lanes are serialised and HREADYOUT is held low until the
// last one has been dealt with, making the whole multi-lane access a single
// AHB transfer.
//
// The stall is bounded by construction -- at most four lanes plus the FIFO's
// one-cycle read latency -- and is never paced by the SPI wire: a full TX
// FIFO or a short RX FIFO ends it immediately and flags OVERFLOW/UNDERFLOW.
// That matters more here than in the SPI Master, because the far end is an
// external host the SoC does not control at all, and cpu_ss is single-master,
// so a held HREADY blocks instruction fetch and the CPU could never run the
// loop that services the FIFO.
//
// Reads are held until every lane has been *assembled*, not merely popped:
// small_sync_fifo registers its read data, so a byte arrives one cycle after
// the pop that fetched it. Retiring on the pop would hand back a word whose
// last lane was still in flight.

  assign lane_index = lane_pending[0] ? 2'd0 :
                      lane_pending[1] ? 2'd1 :
                      lane_pending[2] ? 2'd2 : 2'd3;

  assign tx_wdata = lane_wdata[{3'd0, lane_index} * 4'd8 +: 8];
  assign tx_write = !lane_is_read && (|lane_pending) && !tx_full;
  assign rx_read  =  lane_is_read && (|lane_pending) && !rx_empty;

  assign lane_start_w = data_write && !(|lane_pending);
  // lane_rd_active keeps this to one assertion per transfer: the pipeline
  // freeze holds data_read high for the whole stall, so a start condition
  // written from data_read alone would re-fire every cycle and keep
  // re-clearing the assembly register.
  assign lane_start_r = data_read && !lane_rd_active;

  // Lanes still outstanding *after* this cycle retires.
  //
  // Deliberately computed from the post-edge set rather than from
  // lane_pending directly. lane_pending is a register: on the cycle the
  // access lands it is still zero, so a stall written against it asserts
  // nothing then and holds HREADYOUT low one cycle later, against the *next*
  // transfer. That is exactly how the SPI Master's stall first went wrong
  // (SPIM-ISSUE-031), and it is easy to reintroduce when simplifying.
  always_comb begin
    if (lane_start_w || lane_start_r)
      lane_next = byte_select_r;
    else if (tx_write || rx_read)
      lane_next = lane_pending & ~(4'd1 << lane_index);
    else
      lane_next = lane_pending;
  end

  // Writes retire as soon as the last lane is accepted. Reads additionally
  // wait for the final byte to reach the assembly register, one cycle behind
  // the pop that fetched it 
  // A read is not finished when the last lane is popped: small_sync_fifo
  // registers its read data, so that byte only reaches the assembly register
  // on the following edge. rx_read covers the pop cycle and rx_read_r the
  // write-back cycle, so the transfer retires with the word complete.
  // A read is not finished when the last lane is popped: small_sync_fifo
  // registers its read data, so that byte only reaches the assembly register
  // on the following edge. rx_read covers the pop cycle and rx_read_r the
  // write-back cycle, so the transfer retires with the word complete.
  //
  // lane_start_r is deliberately NOT a stall term on its own: the pipeline
  // freeze holds data_read asserted, so a self-referential start condition
  // would latch the bus low forever.
  // "More than one bit set" - lane_next & (lane_next - 1) clears the lowest
  // set bit, so a nonzero result means at least two lanes remain and another
  // cycle is genuinely needed. A single remaining lane is accepted this cycle
  // and the transfer retires with no wait state, which is what keeps
  // byte-at-a-time firmware zero-wait.
  // Every term is qualified by the access still being present, so the stall
  // cannot outlive the transfer that caused it. rx_read_r in particular is
  // asserted the cycle *after* its pop, which without this qualifier held
  // HREADYOUT low over the start of the next transfer.
  assign lane_stall = (data_write || data_read) &&
                      (((|(lane_next & (lane_next - 4'd1))) &&
                        !(lane_is_read ? rx_empty : tx_full))
                       || (lane_is_read && ((|lane_pending) || rx_read_r))
                       || (lane_start_r && !rx_empty));

  // Bus-side errors: the access asked for more lanes than the FIFO could
  // supply or accept. Distinct from the wire-side events (GRPR-SPIS-028).
  // Any RXDATA read that finds the FIFO short is the bus-side error, whether
  // it is the first lane (an outright empty read) or a later one part way
  // through a packed access.
  assign lane_underflow_evt = data_read && rx_empty;
  assign lane_overflow_evt  = (|lane_pending) && !lane_is_read && tx_full;

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      lane_pending   <= '0;
      lane_wdata     <= '0;
      lane_is_read   <= 1'b0;
      lane_rd_active <= 1'b0;
    end
    else if (fifo_flush) begin
      lane_pending   <= '0;
      lane_is_read   <= 1'b0;
      lane_rd_active <= 1'b0;
    end
    else begin
      // One start per read transfer, cleared when the transfer retires.
      if (lane_start_r)
        lane_rd_active <= 1'b1;
      else if (!data_read)
        lane_rd_active <= 1'b0;

      if (lane_start_w) begin
        // Latch the store; HWDATA is only valid in this data phase.
        lane_wdata   <= HWDATA;
        lane_pending <= byte_select_r;
        lane_is_read <= 1'b0;
      end
      else if (lane_start_r) begin
        lane_pending <= byte_select_r;
        lane_is_read <= 1'b1;
      end
      else if (tx_write || rx_read) begin
        lane_pending[lane_index] <= 1'b0;
      end

      // The FIFO ran out with lanes outstanding: drop them.
      if ((|lane_pending) && (lane_is_read ? rx_empty : tx_full))
        lane_pending <= '0;
    end
  end

  // Assemble popped bytes into the read word, one cycle behind the pop that
  // fetched each one. Cleared when a fresh read starts, so lanes the FIFO
  // could not supply read back as zero (GRPR-SPIS-025).
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      rx_assemble     <= '0;
      rx_lane_index_r <= '0;
      rx_read_r       <= 1'b0;
    end
    else begin
      rx_read_r <= rx_read;
      // The index the in-flight byte belongs to. Sampled with the pop, not
      // after it, so the byte lands in the lane that fetched it.
      if (rx_read)
        rx_lane_index_r <= lane_index;

      if (lane_start_r)
        rx_assemble <= '0;

      if (rx_read_r)
        rx_assemble[{3'd0, rx_lane_index_r} * 4'd8 +: 8] <= rx_rdata;
    end
  end

//------------------------------------------------------
// SPI core
//------------------------------------------------------

  spi_s_core #(
    .DATA_WIDTH    (SPI_S_DATA_W),
    .FIFO_DEPTH    (FIFO_DEPTH),
    .DEBUG_PORT_EN (DEBUG_PORT_EN)
  ) u_core (
    .clk           (HCLK),
    .rst_n         (HRESETn),

    .enable        (ctrl_enable),
    .cpol          (ctrl_cpol),
    .cpha          (ctrl_cpha),
    .flush         (fifo_flush),

    .spi_s_ss        (spi_s_ss),
    .spi_s_sck       (spi_s_sck),
    .spi_s_mosi      (spi_s_mosi),
    .spi_s_miso      (spi_s_miso),

    .rx_read       (rx_read),
    .rx_rdata      (rx_rdata),
    .rx_full       (rx_full),
    .rx_empty      (rx_empty),
    .rx_level      (rx_level),

    .tx_wdata      (tx_wdata),
    .tx_write      (tx_write),
    .tx_full       (tx_full),
    .tx_empty      (tx_empty),

    .busy          (core_busy),
    .rx_overrun    (rx_overrun),
    .rx_pushed     (rx_byte_pushed),
    .tx_underrun   (tx_underrun),

    .dbg_req_valid (dbg_req_valid),
    .dbg_req_ready (dbg_req_ready),
    .dbg_req_cmd   (dbg_req_cmd),
    .dbg_req_addr  (dbg_req_addr),
    .dbg_req_wdata (dbg_req_wdata),
    .dbg_req_size  (dbg_req_size),
    .dbg_rsp_valid (dbg_rsp_valid),
    .dbg_rsp_ready (dbg_rsp_ready),
    .dbg_rsp_rdata (dbg_rsp_rdata),
    .dbg_rsp_err   (dbg_rsp_err),
    .dbg_err_evt   (dbg_err_evt)
  );

  // Soft reset flushes both FIFOs and the framing FSM (SPIS-SPEC-006). It
  // deliberately does not touch IRQ_STATUS: those flags record what already
  // happened and are cleared by a W1C write.
  assign fifo_flush = write_enable && (word_address_r == ADDR_CTRL) &&
                      byte_select_r[0] && HWDATA[1];

//------------------------------------------------------
// Register writes
//------------------------------------------------------

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      ctrl_enable        <= 1'b1;
      ctrl_soft_reset    <= 1'b0;
      ctrl_cpha          <= 1'b0;
      ctrl_cpol          <= 1'b0;

      int_rx_valid  <= 1'b0;
      int_underrun  <= 1'b0;
      int_overrun   <= 1'b0;
      int_underflow <= 1'b0;
      int_overflow  <= 1'b0;

      ie_rx_valid   <= 1'b0;
      ie_underrun   <= 1'b0;
      ie_overrun    <= 1'b0;
      ie_underflow  <= 1'b0;
      ie_overflow   <= 1'b0;
    end
    else begin

      if (write_enable) begin
        unique case (word_address_r)

          ADDR_CTRL: begin
            if (byte_select_r[0]) begin
              ctrl_enable        <= HWDATA[0];
              ctrl_soft_reset    <= HWDATA[1];
              ctrl_cpha          <= HWDATA[2];
              ctrl_cpol          <= HWDATA[3];
              // Bit 4 is reserved: read 0, write 0 (GRPR-SPIS-030, withdrawn).

              // SOFT_RESET is a strobe, not a mode: it self-clears in the
              // cycle it acts (SPIS-SPEC-006). Leaving it set made every
              // later CTRL readback look like a reset was still pending.
              if (HWDATA[1])
                ctrl_soft_reset <= 1'b0;
            end
          end

          // IRQ_STATUS -- write 1 to clear.
          ADDR_IRQ_STS: begin
            if (byte_select_r[0]) begin
              if (HWDATA[0]) int_rx_valid  <= 1'b0;
              if (HWDATA[1]) int_underrun  <= 1'b0;
              if (HWDATA[2]) int_overrun   <= 1'b0;
              if (HWDATA[4]) int_underflow <= 1'b0;
              if (HWDATA[5]) int_overflow  <= 1'b0;
            end
          end

          ADDR_IRQ_EN: begin
            if (byte_select_r[0]) begin
              ie_rx_valid  <= HWDATA[0];
              ie_underrun  <= HWDATA[1];
              ie_overrun   <= HWDATA[2];
              ie_underflow <= HWDATA[4];
              ie_overflow  <= HWDATA[5];
            end
          end

          default: begin end

        endcase
      end

      // Interrupt sources, set AFTER the W1C block above so a source firing
      // in the same cycle as its clear wins. That is the order the
      // specification requires, and the opposite of ahb_spi_m, where the
      // clear is written later and a concurrent event is lost.
      if (rx_byte_pushed || !rx_empty) int_rx_valid  <= 1'b1;
      if (rx_overrun)                  int_overrun   <= 1'b1;  // wire-side
      if (tx_underrun)                 int_underrun  <= 1'b1;  // wire-side
      if (lane_underflow_evt)          int_underflow <= 1'b1;  // bus-side
      if (lane_overflow_evt)           int_overflow  <= 1'b1;  // bus-side
      if (dbg_err_evt)                 int_overrun   <= 1'b1;
    end
  end

//------------------------------------------------------
// Register reads
//------------------------------------------------------

  always_comb begin
    if (!read_enable_r) begin
      HRDATA = '0;
    end
    else begin
      unique case (word_address_r)

        ADDR_CTRL:
          HRDATA = {
            27'b0,
            1'b0,       // bit 4 reserved (GRPR-SPIS-030, withdrawn)
            ctrl_cpol,
            ctrl_cpha,
            ctrl_soft_reset,
            ctrl_enable
          };

        // RX_VALID and TX_READY keep their original bit positions and now
        // read as !rx_empty / !tx_full, so existing firmware sees the same
        // handshake against a deeper buffer.
        ADDR_STATUS:
          HRDATA = {
            20'b0,
            rx_level,
            tx_full,
            tx_empty,
            rx_full,
            rx_empty,
            1'b0,          // DEBUG_BUSY - no debug unit connected yet
            !tx_full,      // TX_READY
            !rx_empty,     // RX_VALID
            core_busy
          };

        // The lane machine assembles the popped bytes low-lane-first; lanes
        // the FIFO could not supply read back as zero.
        ADDR_RXDATA:
          HRDATA = rx_assemble;

        ADDR_IRQ_STS:
          HRDATA = {
            26'b0,
            int_overflow, int_underflow, 1'b0,
            int_overrun,  int_underrun,  int_rx_valid
          };

        ADDR_IRQ_EN:
          HRDATA = {
            26'b0,
            ie_overflow, ie_underflow, 1'b0,
            ie_overrun,  ie_underrun,  ie_rx_valid
          };

        default:
          HRDATA = '0;

      endcase
    end
  end

//------------------------------------------------------
// AHB error response and wait states
//------------------------------------------------------
// AHB-Lite ERROR is two cycles: HREADYOUT low with HRESP high, then
// HREADYOUT high with HRESP high (SPIS-SPEC-009). This was a one-cycle
// response before, which is a protocol violation -- and it matters more now
// that the lane machine drives HREADYOUT for the first time, since the two
// share the signal.

  always_comb begin
    invalid_access = 1'b0;

    if (write_enable) begin
      unique case (word_address_r)
        ADDR_STATUS: invalid_access |= 1'b1;  // read-only
        ADDR_RXDATA: invalid_access |= 1'b1;  // read-only
        default:     begin end
      endcase
    end

    // Offsets past the end of the map error on read and write alike.
    if ((write_enable || read_enable_r) && (word_address_r > ADDR_SPI_S_MAX))
      invalid_access |= 1'b1;
  end

  assign err_req = invalid_access && !err_second_cycle;

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn)
      err_second_cycle <= 1'b0;
    else
      err_second_cycle <= err_req;
  end

  assign HRESP = err_req || err_second_cycle;

  // Two independent reasons to hold the bus. The error response wins: once
  // err_req is asserted the transfer is being aborted, and the second ERROR
  // cycle must present HREADYOUT high on schedule regardless of what the lane
  // machine is doing.
  assign HREADYOUT = err_second_cycle ? 1'b1 : (~err_req && ~lane_stall);

//------------------------------------------------------
// Interrupt output (GRPR-SPIS-029)
//------------------------------------------------------
// Single-level gating: IRQ_EN is the only gate. The SPI Master's extra
// CTRL.IE_COMPLETE/IE_ERR pair exists to separate completion from error
// reporting on a block that raises both; this block has no transaction-
// complete event of its own.
//
// The output has no CPU interrupt line today -- cpu_ss's vector is full -- so
// it joins QSPI's and the SPI Master's as an unconnected port at periph_ss
// and firmware polls IRQ_STATUS (SPIS-SPEC-012).

  assign irq = (int_rx_valid  && ie_rx_valid)  ||
               (int_underrun  && ie_underrun)  ||
               (int_overrun   && ie_overrun)   ||
               (int_underflow && ie_underflow) ||
               (int_overflow  && ie_overflow);

endmodule
