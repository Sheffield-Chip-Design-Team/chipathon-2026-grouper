// SPI slave core: command framing, RX and TX paths, and the debug transport.
//
// The register file lives in ahb_spi_s; everything wire-facing lives here.
// Frame shape follows the APS6404L SPI-mode commands (GRPR-SPIS-003):
//
//   opcode (8) -> address (24) -> data (N)
//
// Only the data phase is payload. The opcode identifies the frame and goes to
// the command register; the address feeds the debug transport.

module spi_s_core #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4,
  parameter int DEBUG_PORT_EN = 0
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // Control
  input  logic                  enable,
  input  logic                  cpol,
  input  logic                  cpha,
  input  logic                  debug_port_en,
  input  logic                  flush,

  // Wire side
  input  logic                  spi_ss,
  input  logic                  spi_sck,
  input  logic                  spi_mosi,
  output logic                  spi_miso,

  // RX FIFO read side
  input  logic                  rx_read,
  output logic [DATA_WIDTH-1:0] rx_rdata,
  output logic                  rx_full,
  output logic                  rx_empty,
  output logic [3:0]            rx_level,

  // TX FIFO write side
  input  logic [DATA_WIDTH-1:0] tx_wdata,
  input  logic                  tx_write,
  output logic                  tx_full,
  output logic                  tx_empty,

  // Status and in-transfer events
  output logic                  busy,
  output logic                  rx_overrun,
  output logic                  rx_pushed,
  output logic                  tx_underrun,

  // Debug port (GRPR-SPIS-030 .. -035)
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
  output logic                  dbg_err_evt
);

  // SPI command codes
  localparam logic [7:0] SPI_WRITE  = 8'h02;
  localparam logic [7:0] SPI_READ   = 8'h03;
  localparam logic [7:0] FAST_WRITE = 8'h0A;
  localparam logic [7:0] FAST_READ  = 8'h0B;

  // Debug port commands, from the Debug Unit's "Debug Port Commands".
  localparam logic [3:0] DBG_CMD_READ  = 4'h3;
  localparam logic [3:0] DBG_CMD_WRITE = 4'h4;

  typedef enum logic [2:0] {
    FSM_IDLE,
    FSM_COMMAND,
    FSM_ADDRESS,
    FSM_READ_DATA,
    FSM_WRITE_DATA
  } spi_state_t;

  spi_state_t spi_state;

  logic [7:0]  spi_command;
  logic [23:0] spi_address;
  // The top bit shifts out as the 24th address bit lands: spi_address takes
  // it from spi_mosi directly, so address_shift[23] is never read back.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [23:0] address_shift;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [4:0]  address_bit_count;

  logic spi_sck_d;
  logic sample_edge;
  logic launch_edge;

  logic                  rx_byte_done;
  logic [DATA_WIDTH-1:0] rx_byte_data;
  logic                  rx_push_en;

  logic spi_miso_int;
  logic tx_busy;
  logic tx_underrun_int;

  logic dbg_active;
  logic dbg_is_read;
  logic [DATA_WIDTH-1:0] dbg_rsp_byte;
  logic                  dbg_rsp_byte_valid;

//------------------------------------------------------
// Clock edge selection (GRPR-SPIS-002, SPIS-SPEC-005)
//------------------------------------------------------
// Only modes 0 and 3 exist. In both the sampling edge is the one driving SCK
// to its active level and the launch edge is the other, so a single
// CPOL-selected pair covers them; CPHA is required to equal CPOL.


  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) spi_sck_d <= 1'b0;
    else        spi_sck_d <= spi_sck;

  assign sample_edge = cpol ? (!spi_sck &&  spi_sck_d)
                            : ( spi_sck && !spi_sck_d);
  assign launch_edge = cpol ? ( spi_sck && !spi_sck_d)
                            : (!spi_sck &&  spi_sck_d);

//------------------------------------------------------
// Command framing FSM
//------------------------------------------------------

  assign busy = !spi_ss && (spi_state != FSM_IDLE);

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      spi_state         <= FSM_IDLE;
      spi_command       <= '0;
      spi_address       <= '0;
      address_shift     <= '0;
      address_bit_count <= '0;
    end
    else if (flush) begin
      spi_state         <= FSM_IDLE;
      spi_command       <= '0;
      spi_address       <= '0;
      address_shift     <= '0;
      address_bit_count <= '0;
    end
    else begin
      if (spi_ss) begin
        // SS high returns the decoder to idle, which is how a host
        // resynchronises after an aborted frame (GRPR-SPIS-022).
        spi_state         <= FSM_IDLE;
        address_bit_count <= 5'd0;
      end
      else if (spi_state == FSM_IDLE) begin
        spi_state <= FSM_COMMAND;
      end

      // A read burst advances when the Debug Unit accepts each request.
      // Outside the sample_edge guard because the handshake is paced by the
      // bus, not by SCK.
      if (!spi_ss && dbg_active && dbg_is_read &&
          dbg_req_valid && dbg_req_ready)
        spi_address <= spi_address + 24'd1;

      if (!spi_ss && sample_edge) begin

        if (spi_state == FSM_COMMAND) begin
          if (rx_byte_done) begin
            spi_command <= rx_byte_data;

            unique case (rx_byte_data)
              SPI_WRITE, SPI_READ, FAST_WRITE, FAST_READ:
                spi_state <= FSM_ADDRESS;
              default:
                spi_state <= FSM_IDLE;
            endcase
          end
        end

        // Multi-byte bursts walk consecutive ascending addresses
        // (GRPR-SPIS-034, mirroring GRPR-DBG-012). Without this every byte of
        // a burst would target the address the frame opened with.
        else if ((spi_state == FSM_WRITE_DATA) && rx_byte_done && dbg_active)
          spi_address <= spi_address + 24'd1;

        else if (spi_state == FSM_ADDRESS) begin
          address_shift <= {address_shift[22:0], spi_mosi};

          if (address_bit_count == 5'd23) begin
            spi_address       <= {address_shift[22:0], spi_mosi};
            address_bit_count <= 5'd0;

            if (spi_command == SPI_READ || spi_command == FAST_READ)
              spi_state <= FSM_READ_DATA;
            else
              spi_state <= FSM_WRITE_DATA;
          end
          else begin
            address_bit_count <= address_bit_count + 5'd1;
          end
        end
      end
    end
  end

//------------------------------------------------------
// Receive path
//------------------------------------------------------
// Payload only: the opcode identifies the frame and the address phase is
// consumed above, so only data-phase bytes reach the FIFO. On the debug path
// they are forwarded to the bus instead (GRPR-SPIS-032).

  assign rx_push_en = (spi_state == FSM_WRITE_DATA) && !dbg_active;

  // A payload byte actually entered the FIFO -- the RX_VALID interrupt source.
  assign rx_pushed  = rx_byte_done && rx_push_en && !rx_full;

  spi_s_rx #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_rx (
    .clk         (clk),
    .rst_n       (rst_n),
    .flush       (flush),
    .spi_ss      (spi_ss),
    .spi_mosi    (spi_mosi),
    .sample_edge (sample_edge),
    .push_en     (rx_push_en),
    .byte_done   (rx_byte_done),
    .byte_data   (rx_byte_data),
    .read        (rx_read),
    .rdata       (rx_rdata),
    .full        (rx_full),
    .empty       (rx_empty),
    .level       (rx_level),
    .overrun     (rx_overrun)
  );

//------------------------------------------------------
// Transmit path
//------------------------------------------------------

  spi_s_tx #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_tx (
    .clk         (clk),
    .rst_n       (rst_n),
    .flush       (flush),
    .spi_ss      (spi_ss),
    .launch_edge (launch_edge),
    .miso        (spi_miso_int),
    .send_en     (spi_state == FSM_READ_DATA),
    .ext_valid   (dbg_active && dbg_is_read && dbg_rsp_byte_valid),
    .ext_data    (dbg_rsp_byte),
    .wdata       (tx_wdata),
    .write       (tx_write),
    .full        (tx_full),
    .empty       (tx_empty),
    .busy        (tx_busy),
    .underrun    (tx_underrun_int)
  );

  // ENABLE gates the wire output only; the block still frames what it sees.
  assign spi_miso = (enable && !spi_ss) ? spi_miso_int : 1'b0;

  // The debug path has no TX FIFO to run dry, so underrun is a FIFO-path
  // event only.
  assign tx_underrun = tx_underrun_int && !dbg_active;

//------------------------------------------------------
// Debug transport (GRPR-SPIS-030 .. -035)
//------------------------------------------------------
// With CTRL.DEBUG_PORT_EN set, SPI_READ/SPI_WRITE are forwarded as debug bus
// requests at the captured 24-bit address instead of terminating in the
// FIFOs. This block only frames and forwards -- the Debug Unit owns the bus
// and decides whether a request is permitted.
//
// The 24-bit address is zero-extended and interpreted in the CPU's own map,
// so it lands in the [31:29]==000 slice: ROM or RAM, depending on the bank
// switch. It cannot express a peripheral address, which needs bit 31 -- that
// is what the Debug Unit's own 32-bit BUS_READ/BUS_WRITE opcodes are for. The
// limitation is structural, not a policy choice (GRPR-SPIS-031).

  assign dbg_active = (DEBUG_PORT_EN != 0) && debug_port_en &&
                      ((spi_command == SPI_READ)  ||
                       (spi_command == SPI_WRITE) ||
                       (spi_command == FAST_READ) ||
                       (spi_command == FAST_WRITE));

  assign dbg_is_read = (spi_command == SPI_READ) || (spi_command == FAST_READ);

  // One request per payload byte, at the auto-incrementing address
  // (GRPR-SPIS-034). Byte-sized, since the SPI frame is a byte stream.
  // The write side must be qualified by FSM_WRITE_DATA: rx_byte_done fires on
  // every completed byte, so without it the opcode and the three address
  // bytes each issued a spurious request at whatever address the frame had
  // captured so far -- four bogus writes to address 0 before the real one.
  assign dbg_req_valid = dbg_active && !spi_ss &&
                         (dbg_is_read ? ((spi_state == FSM_READ_DATA) &&
                                         !tx_busy && !dbg_rsp_byte_valid)
                                      : ((spi_state == FSM_WRITE_DATA) &&
                                         rx_byte_done));
                                         
  assign dbg_req_cmd   = dbg_is_read ? DBG_CMD_READ : DBG_CMD_WRITE;
  assign dbg_req_addr  = {8'b0, spi_address};
  assign dbg_req_wdata = {24'b0, rx_byte_data};
  assign dbg_req_size  = 2'd0;
  assign dbg_rsp_ready = dbg_active;

  // A read response supplies the byte the shifter sends next. An error is
  // reported through IRQ_STATUS rather than stalling the wire: the host is
  // clocking SCK and cannot be held off, so the transfer completes with
  // whatever the bus returned (GRPR-SPIS-033).
  assign dbg_err_evt = dbg_rsp_valid && dbg_rsp_ready && dbg_rsp_err;

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      dbg_rsp_byte       <= '0;
      dbg_rsp_byte_valid <= 1'b0;
    end
    else if (flush || spi_ss) begin
      dbg_rsp_byte       <= '0;
      dbg_rsp_byte_valid <= 1'b0;
    end
    else begin
      if (dbg_rsp_valid && dbg_rsp_ready && !dbg_rsp_err) begin
        dbg_rsp_byte       <= dbg_rsp_rdata[7:0];
        dbg_rsp_byte_valid <= 1'b1;
      end
      // Consumed once the shifter has taken it.
      else if (tx_busy) begin
        dbg_rsp_byte_valid <= 1'b0;
      end
    end
  end

endmodule
