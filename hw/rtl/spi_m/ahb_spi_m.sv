// AHB-Lite SPI master.
//
// Register map (GRPR-SPIM-001):
//   0x00 CTRL        R/W   CPHA[0] CPOL[1] ENABLE[3] CLKDIV[15:8]
//                          IE_COMPLETE[16] IE_ERR[17]
//   0x04 CMD         R/W   START[0] OPCODE[8:1] CMD_EN[9] ADDR_EN[10]
//                          ADDR_BYTES[12:11] DATA_EN[13] DIR[14] DUMMY[19:15]
//                          DATA_LEN[27:20] RX_FLUSH[28] TX_FLUSH[29]
//   0x08 STATUS      RO    BUSY[0] TX_EMPTY[1] TX_FULL[2] RX_EMPTY[3] RX_FULL[4]
//   0x0C IRQ_STATUS  W1C   TXN_COMPLETE[0] UNDERRUN[1] OVERRUN[2] CFG_ERR[3]
//                          UNDERFLOW[4] OVERFLOW[5]
//   0x10 IRQ_EN      R/W   same bit positions as IRQ_STATUS
//   0x14 ADDR        R/W   address-phase payload
//   0x18 DATA        R/W   TX FIFO push (write, 1-4 bytes by HSIZE) /
//                          RX FIFO pop (read)
//
// OVERRUN/UNDERRUN are the in-transfer (wire-side) FIFO events; 
// OVERFLOW/UNDERFLOW are the AHB access errors. 

// See the IRQ_STATUS section of the specification.

module ahb_spi_m #(
  parameter int ADDR_WIDTH = 5,
  parameter int DATA_WIDTH = 32,
  // TX and RX FIFO depth. small_sync_fifo requires a power of two; the block
  // supports up to 8 entries (GRPR-SPIM-017).
  parameter int FIFO_DEPTH = 4
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  /* verilator lint_off UNUSEDSIGNAL */
  input logic [ADDR_WIDTH-1:0]  HADDR,

  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,

  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,

  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  input logic                   HREADYIN,
  input logic                   HSEL,
  /* verilator lint_on UNUSEDSIGNAL */

  output logic                  spi_m_mosi_o,
  output logic                  spi_m_sck_o,
  output logic                  spi_m_cs_n_o,
  input  logic                  spi_m_miso_i,

  output logic                  irq
);

  import ahb3lite_pkg::*;

  initial begin : check_fifo_depth
    if (FIFO_DEPTH != 2 && FIFO_DEPTH != 4 && FIFO_DEPTH != 8)
      $error("%m: FIFO_DEPTH must be 2, 4 or 8 (GRPR-SPIM-017)");
  end

  // Word offsets
  localparam logic [2:0] ADDR_CTRL      = 3'd0;  // 0x00
  localparam logic [2:0] ADDR_CMD       = 3'd1;  // 0x04
  localparam logic [2:0] ADDR_STATUS    = 3'd2;  // 0x08
  localparam logic [2:0] ADDR_INT_STS   = 3'd3;  // 0x0C
  localparam logic [2:0] ADDR_INT_EN    = 3'd4;  // 0x10
  localparam logic [2:0] ADDR_ADDR      = 3'd5;  // 0x14
  localparam logic [2:0] ADDR_DATA      = 3'd6;  // 0x18
  localparam logic [2:0] ADDR_SPI_M_MAX = 3'd6;

  // CTRL -- GRPR-SPIM-009, GRPR-SPIM-012
  logic        ctrl_cpha;
  logic        ctrl_cpol;
  logic        ctrl_enable;
  logic [7:0]  ctrl_clk_div;
  logic        ctrl_ie_done;
  logic        ctrl_ie_err;

  // CMD
  logic [7:0]  cmd_opcode;
  logic        cmd_en;
  logic        cmd_addr_en;
  logic [1:0]  cmd_addr_bytes;
  logic        cmd_data_en;
  logic        cmd_dir;
  logic [4:0]  cmd_dummy;
  logic [7:0]  cmd_len;

  // IRQ_STATUS. run = in-transfer (wire) event, flow = AHB access error.
  logic        int_done;
  logic        int_overrun;    // RX byte arrived, RX FIFO full
  logic        int_underrun;   // TX byte needed, TX FIFO empty
  logic        int_cfg_err;
  logic        int_underflow;  // AHB read of an empty RX FIFO
  logic        int_overflow;   // AHB write to a full TX FIFO

  // IRQ_EN, same bit positions as IRQ_STATUS
  logic        ie_done;
  logic        ie_overrun;
  logic        ie_underrun;
  logic        ie_cfg_err;
  logic        ie_underflow;
  logic        ie_overflow;

  logic [31:0] spi_addr;
  logic [7:0]  rx_last_data;

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

  // Core interface
  logic                       spi_start;
  logic                       spi_busy;
  logic                       spi_done;
  logic [7:0]                 rx_data;
  logic                       rx_full;
  logic                       rx_empty;
  logic                       rx_overrun;
  logic                       tx_full;
  logic                       tx_empty;
  logic                       tx_underrun;
  logic                       flush_tx;
  logic                       flush_rx;

  logic                       cfg_error_access;
  logic                       err_second_cycle;

  logic                       data_write;
  logic                       data_read;
  logic                       data_read_ap;
  logic                       rx_pop_valid;

  // Multi-byte DATA push (SPIM-ISSUE-017)
  logic [3:0]                 push_pending;   // byte lanes still to push
  logic [DATA_WIDTH-1:0]      push_data;
  logic                       push_active;
  logic                       push_start;
  logic [1:0]                 push_index;
  logic                       tx_push;
  logic [7:0]                 tx_push_data;

  // Error response
  logic err_req;
//------------------------------------------------------
// AHB address phase decode
//------------------------------------------------------

  assign access       = HREADYIN && HSEL &&
                        (HTRANS == HTRANS_NONSEQ || HTRANS == HTRANS_SEQ);
  assign read_enable  = access && ~HWRITE;
  assign word_address = access ? HADDR[4:2] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

//------------------------------------------------------
// AHB pipeline register
//------------------------------------------------------
// HWDATA is valid in the DATA phase, i.e. the cycle after the address phase,
// so it is used directly here rather than registered off the address-phase
// edge (SPIM-ISSUE-013).

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn) begin
      write_enable   <= '0;
      read_enable_r  <= '0;
      rx_pop_valid   <= '0;
      word_address_r <= '0;
      byte_select_r  <= '0;
    end else begin
      write_enable   <= access && HWRITE;
      read_enable_r  <= read_enable;
      rx_pop_valid   <= data_read_ap && !rx_empty;
      word_address_r <= word_address;
      byte_select_r  <= byte_select;
    end
  end

//------------------------------------------------------
// Register write
//------------------------------------------------------

  assign data_write = write_enable && (word_address_r == ADDR_DATA);
  assign data_read  = read_enable_r && (word_address_r == ADDR_DATA);

  // small_sync_fifo registers rdata, so a pop issued in the address phase
  // presents its data in the data phase -- exactly where HRDATA is sampled.
  // Popping in the data phase instead would return the previous entry
  // (SPIM-ISSUE-011).
  assign data_read_ap = read_enable && (word_address == ADDR_DATA);

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn) begin
      ctrl_cpha      <= 1'b0;
      ctrl_cpol      <= 1'b0;
      ctrl_enable    <= 1'b0;
      ctrl_clk_div   <= 8'd1;      // 4 MHz from a 16 MHz clock -- GRPR-SPIM-013
      ctrl_ie_done   <= 1'b0;
      ctrl_ie_err    <= 1'b0;

      cmd_opcode     <= 8'h00;
      cmd_en         <= 1'b0;
      cmd_addr_en    <= 1'b0;
      cmd_addr_bytes <= 2'b00;
      cmd_data_en    <= 1'b0;
      cmd_dir        <= 1'b0;
      cmd_dummy      <= 5'd0;
      cmd_len        <= 8'h00;

      spi_addr       <= 32'h0;
      rx_last_data   <= 8'h0;

      int_done       <= 1'b0;
      int_overrun    <= 1'b0;
      int_underrun   <= 1'b0;
      int_cfg_err    <= 1'b0;
      int_underflow  <= 1'b0;
      int_overflow   <= 1'b0;

      ie_done        <= 1'b0;
      ie_overrun     <= 1'b0;
      ie_underrun    <= 1'b0;
      ie_cfg_err     <= 1'b0;
      ie_underflow   <= 1'b0;
      ie_overflow    <= 1'b0;

      spi_start      <= 1'b0;
      flush_tx       <= 1'b0;
      flush_rx       <= 1'b0;
    end else begin
      // START and the flushes are single-cycle pulses -- SPIM-ISSUE-005.
      spi_start <= 1'b0;
      flush_tx  <= 1'b0;
      flush_rx  <= 1'b0;

      if (spi_done)
        int_done <= 1'b1;

      // In-transfer FIFO events -- SPIM-ISSUE-018.
      if (rx_overrun)
        int_overrun <= 1'b1;
      if (tx_underrun)
        int_underrun <= 1'b1;

      if (write_enable)
        unique case (word_address_r)

          ADDR_CTRL: begin
            if (byte_select_r[0]) begin
              // Writing CTRL while busy is ignored and flags CFG_ERR, as is
              // an illegal CPOL/CPHA pair -- GRPR-SPIM-016.
              if (spi_busy || (HWDATA[0] != HWDATA[1])) begin
                int_cfg_err <= 1'b1;
              end else begin
                ctrl_cpha    <= HWDATA[0];
                ctrl_cpol    <= HWDATA[1];
                ctrl_enable  <= HWDATA[3];
                ctrl_clk_div <= HWDATA[15:8];
                ctrl_ie_done <= HWDATA[16];
                ctrl_ie_err  <= HWDATA[17];
              end
            end
          end

          ADDR_CMD: begin
            if (byte_select_r[0]) begin
              // START while BUSY, or while the block is disabled, is a
              // configuration error.
              if (spi_busy || (HWDATA[0] && !ctrl_enable)) begin
                int_cfg_err <= 1'b1;
              end else begin
                spi_start      <= HWDATA[0];
                cmd_opcode     <= HWDATA[8:1];
                cmd_en         <= HWDATA[9];
                cmd_addr_en    <= HWDATA[10];
                cmd_addr_bytes <= HWDATA[12:11];
                cmd_data_en    <= HWDATA[13];
                cmd_dir        <= HWDATA[14];
                cmd_dummy      <= HWDATA[19:15];
                cmd_len        <= HWDATA[27:20];
                flush_rx       <= HWDATA[28];
                flush_tx       <= HWDATA[29];
              end
            end
          end

          ADDR_INT_STS: begin
            if (byte_select_r[0]) begin
              if (HWDATA[0]) int_done     <= 1'b0;
              if (HWDATA[1]) int_underrun <= 1'b0;
              if (HWDATA[2]) int_overrun  <= 1'b0;
              if (HWDATA[3]) int_cfg_err  <= 1'b0;
              if (HWDATA[4]) int_underflow <= 1'b0;
              if (HWDATA[5]) int_overflow  <= 1'b0;
            end
          end

          ADDR_INT_EN: begin
            if (byte_select_r[0]) begin
              ie_done     <= HWDATA[0];
              ie_underrun <= HWDATA[1];
              ie_overrun  <= HWDATA[2];
              ie_cfg_err  <= HWDATA[3];
              ie_underflow <= HWDATA[4];
              ie_overflow  <= HWDATA[5];
            end
          end

          // Byte strobes honoured, matching the other registers
          // (SPIM-ISSUE-019).
          ADDR_ADDR: begin
            if (byte_select_r[0]) spi_addr[7:0]   <= HWDATA[7:0];
            if (byte_select_r[1]) spi_addr[15:8]  <= HWDATA[15:8];
            if (byte_select_r[2]) spi_addr[23:16] <= HWDATA[23:16];
            if (byte_select_r[3]) spi_addr[31:24] <= HWDATA[31:24];
          end

          ADDR_DATA: begin
            // A push to a full TX FIFO is dropped. That is an AHB access
            // error, so it flags OVERFLOW -- distinct from OVERRUN, which is
            // the in-transfer event of an RX byte arriving with the RX FIFO
            // full (SPIM-SPEC-001).
            if (tx_full)
              int_overflow <= 1'b1;
          end

          default: begin end
        endcase

      // UNDERFLOW is decided in the address phase, where rx_empty still
      // describes the FIFO the access is about to read. It is the AHB-side
      // error -- reading an empty RX FIFO -- as opposed to UNDERRUN, which is
      // the in-transfer event of a data byte being needed with the TX FIFO
      // empty (SPIM-SPEC-001).
      if (data_read && !rx_pop_valid)
        int_underflow <= 1'b1;
      if (rx_pop_valid)
        rx_last_data <= rx_data;
    end
  end

//------------------------------------------------------
// Multi-byte DATA push
//------------------------------------------------------
// A DATA write pushes 1-4 bytes depending on HSIZE (SPIM-ISSUE-017), so
// firmware can hand over four bytes in one 32-bit store. small_sync_fifo
// takes one write per cycle, so the lanes are serialised here and the AHB
// transfer is stalled with HREADYOUT until they drain.
//
// Lanes are pushed low byte first, which is the order the address phase and
// the APS6404L both expect: a store of 0xDDCCBBAA sends AA, BB, CC, DD.
//
// If the FIFO fills part way through, the remaining lanes are dropped and
// OVERFLOW is set

  // The lanes this store wants to push, from the byte strobes.
  logic [3:0] write_lanes;
  assign write_lanes = byte_select_r;

  // Gate on the lanes still outstanding rather than on push_active. The flag
  // is cleared a cycle after the last lane drains, so a back-to-back DATA
  // store - which is what a byte-at-a-time push looks like - arrived while it
  // was still set and was silently dropped, losing that byte entirely.
  // push_pending is the real "still busy" condition, and it is already zero
  // on the cycle the store lands.
  assign push_start = data_write && !(|push_pending);

  // Select the lowest still-pending lane.
  always_comb begin
    push_index = 2'd0;
    if      (push_pending[0]) push_index = 2'd0;
    else if (push_pending[1]) push_index = 2'd1;
    else if (push_pending[2]) push_index = 2'd2;
    else if (push_pending[3]) push_index = 2'd3;
  end

  assign tx_push_data = push_data[{3'd0, push_index} * 4'd8 +: 8];
  assign tx_push      = (|push_pending) && !tx_full;

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn) begin
      push_pending <= '0;
      push_data    <= '0;
      push_active  <= 1'b0;
    end else if (flush_tx) begin
      push_pending <= '0;
      push_active  <= 1'b0;
    end else begin
      if (push_start) begin
        // Latch the store; HWDATA is only valid in this data phase.
        push_data    <= HWDATA;
        push_pending <= write_lanes;
        push_active  <= 1'b1;
      end else if (tx_push) begin
        push_pending[push_index] <= 1'b0;
      end

      // Done once every lane has been pushed or dropped.
      if (push_active && !(|push_pending))
        push_active <= 1'b0;

      // The FIFO filled with lanes outstanding: drop them.
      if (push_active && tx_full && (|push_pending))
        push_pending <= '0;
    end
  end

//------------------------------------------------------
// Read mux
//------------------------------------------------------

  always_comb begin
    if (!read_enable_r)
      HRDATA = '0;
    else
      unique case (word_address_r)

        ADDR_CTRL: HRDATA = {
            14'b0,
            ctrl_ie_err,        // 17
            ctrl_ie_done,       // 16
            ctrl_clk_div,       // 15:8
            4'b0,               // 7:4
            ctrl_enable,        // 3
            1'b0,               // 2
            ctrl_cpol,          // 1
            ctrl_cpha           // 0
        };

        // START always reads 0 -- it is a self-clearing pulse.
        ADDR_CMD: HRDATA = {
            4'b0,
            cmd_len,            // 27:20
            cmd_dummy,          // 19:15
            cmd_dir,            // 14
            cmd_data_en,        // 13
            cmd_addr_bytes,     // 12:11
            cmd_addr_en,        // 10
            cmd_en,             // 9
            cmd_opcode,         // 8:1
            1'b0                // 0  START
        };

        ADDR_STATUS: HRDATA = {
            27'd0,
            rx_full,            // 4
            rx_empty,           // 3
            tx_full,            // 2
            tx_empty,           // 1
            spi_busy            // 0
        };

        ADDR_INT_STS: HRDATA = {
            26'b0,
            int_overflow,
            int_underflow,
            int_cfg_err,
            int_overrun,
            int_underrun,
            int_done
        };

        ADDR_INT_EN: HRDATA = {
            26'b0,
            ie_overflow,
            ie_underflow,
            ie_cfg_err,
            ie_overrun,
            ie_underrun,
            ie_done
        };

        ADDR_ADDR: HRDATA = spi_addr;

        // Reading an empty RX FIFO returns the last popped value.
        // small_sync_fifo registers rdata, so the pop issued in this cycle
        // presents its data next cycle; rx_data here is the entry at the
        // current read pointer, which is the one this access pops
        // (SPIM-ISSUE-011).
        ADDR_DATA: HRDATA = rx_pop_valid
            ? {{(DATA_WIDTH-8){1'b0}}, rx_data}
            : {{(DATA_WIDTH-8){1'b0}}, rx_last_data};

        default: HRDATA = '0;

      endcase
  end

//------------------------------------------------------
// SPI core instantiation
//------------------------------------------------------

  spi_m_core #(
      .CLK_DIV_BITS (8),
      .DATA_WIDTH   (8),
      .FIFO_DEPTH   (FIFO_DEPTH)
  ) u_spi_m_core (
      .clk            (HCLK),
      .rst_n          (HRESETn),

      .clk_div        (ctrl_clk_div),
      .cpol           (ctrl_cpol),
      .cpha           (ctrl_cpha),
      .enable         (ctrl_enable),

      .start          (spi_start),
      .opcode         (cmd_opcode),
      .cmd_en         (cmd_en),
      .addr_en        (cmd_addr_en),
      .addr_bytes     (cmd_addr_bytes),
      .addr           (spi_addr),
      .data_en        (cmd_data_en),
      .dir            (cmd_dir),
      .dummy_cycles   (cmd_dummy),
      .data_len       (cmd_len),

      .flush_tx_fifo  (flush_tx),
      .tx_write       (tx_push),
      .tx_data        (tx_push_data),
      .tx_full        (tx_full),
      .tx_empty       (tx_empty),
      .tx_underrun    (tx_underrun),

      .flush_rx_fifo  (flush_rx),
      .rx_read        (data_read_ap && !rx_empty),
      .rx_data        (rx_data),
      .rx_full        (rx_full),
      .rx_empty       (rx_empty),
      .rx_overrun     (rx_overrun),

      .busy           (spi_busy),
      .done           (spi_done),

      .spi_mosi       (spi_m_mosi_o),
      .spi_miso       (spi_m_miso_i),
      .spi_sck        (spi_m_sck_o),
      .spi_cs_n       (spi_m_cs_n_o)
  );

//------------------------------------------------------
// IRQ
//------------------------------------------------------

  assign irq = (int_done && ctrl_ie_done && ie_done) ||
               (ctrl_ie_err && ((int_overrun   && ie_overrun)   ||
                                (int_underrun  && ie_underrun)  ||
                                (int_overflow  && ie_overflow)  ||
                                (int_underflow && ie_underflow) ||
                                (int_cfg_err   && ie_cfg_err)));

//------------------------------------------------------
// Invalid access / configuration detection
//------------------------------------------------------

  assign invalid_access = (write_enable && (word_address_r == ADDR_STATUS)) ||
                          ((write_enable || read_enable_r) &&
                           (word_address_r > ADDR_SPI_M_MAX));

  // Illegal CPOL/CPHA pair -- GRPR-SPIM-016.
  assign cfg_error_access = write_enable && (word_address_r == ADDR_CTRL) &&
                            byte_select_r[0] && (HWDATA[0] != HWDATA[1]);

//------------------------------------------------------
// AHB error response
//------------------------------------------------------
// AHB-Lite ERROR is two cycles: HREADYOUT low with HRESP high, then
// HREADYOUT high with HRESP high (SPIM-ISSUE-014).

  assign err_req = (invalid_access || cfg_error_access) && !err_second_cycle;

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn)
      err_second_cycle <= 1'b0;
    else
      err_second_cycle <= err_req;
  end
  // Cycle 1 (Data Phase): HRESP high, HREADYOUT low. Cycle 2: HRESP high, HREADYOUT high.
  assign HRESP     = err_req || err_second_cycle;

  assign HREADYOUT = ~err_req;

endmodule
