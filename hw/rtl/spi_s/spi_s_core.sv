// SPI slave core: command framing, RX and TX paths, and the debug transport.
//
// The register file lives in ahb_spi_s; everything wire-facing lives here.
// Two independent command families share the wire:
//
//  - The legacy APS6404L-compatible data commands (GRPR-SPIS-003):
//      opcode (8) -> address (24) -> data (N)
//    These always terminate in the RX/TX FIFOs. They never touch the debug
//    port, at any register or parameter setting (GRPR-SPIS-030, withdrawn).
//  - The dedicated debug opcodes of the Debug Unit's wire protocol
//    (GRPR-SPIS-041/-044), present only under the DEBUG_PORT_EN parameter,
//    each mapping to exactly one dbg_req_cmd. See § Debug Command Encoding
//    in the SPI Slave Specification for the full opcode table and framing.

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
  // Only [7:0] is consumed: dbg_req_size is always 0, so every response is a
  // single byte (GRPR-SPIS-030). The port stays 32 bits wide because the
  // Debug Port Interface defines it that way and a transport does not get to
  // narrow it.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0]           dbg_rsp_rdata,
  /* verilator lint_on UNUSEDSIGNAL */

  input  logic                  dbg_rsp_err,
  output logic                  dbg_err_evt
);

  // Legacy APS6404L-compatible SPI command codes (24-bit address, GRPR-SPIS-030).
  localparam logic [7:0] SPI_WRITE  = 8'h02;
  localparam logic [7:0] SPI_READ   = 8'h03;
  localparam logic [7:0] FAST_WRITE = 8'h0A;
  localparam logic [7:0] FAST_READ  = 8'h0B;

  // Dedicated debug opcodes (32-bit address / no address, GRPR-SPIS-041/-044).
  localparam logic [7:0] OP_BUS_WRITE   = 8'h51;
  localparam logic [7:0] OP_BUS_READ    = 8'h52;
  localparam logic [7:0] OP_BUS_STATUS  = 8'h53;
  localparam logic [7:0] OP_DBG_READ    = 8'h54;
  localparam logic [7:0] OP_DBG_ENABLE  = 8'h55;
  // 0x56 reserved (GRPR-SPIS-048), decoded to nothing below.
  localparam logic [7:0] OP_DBG_RESUME  = 8'h57;
  localparam logic [7:0] OP_DBG_STEP    = 8'h58;
  localparam logic [7:0] OP_BUS_LOCK    = 8'h5A;
  localparam logic [7:0] OP_BUS_UNLOCK  = 8'hA5;

  // Debug port commands, from the Debug Unit's "Debug Port Commands".
  localparam logic [3:0] DBG_CMD_LOCK       = 4'h1;
  localparam logic [3:0] DBG_CMD_UNLOCK     = 4'h2;
  localparam logic [3:0] DBG_CMD_READ       = 4'h3;
  localparam logic [3:0] DBG_CMD_WRITE      = 4'h4;
  localparam logic [3:0] DBG_CMD_STATUS     = 4'h5;
  localparam logic [3:0] DBG_CMD_STATE_READ = 4'h6;
  localparam logic [3:0] DBG_CMD_STEP       = 4'h7;
  localparam logic [3:0] DBG_CMD_RESUME     = 4'h8;
  localparam logic [3:0] DBG_CMD_DBG_ENABLE = 4'hC;

  typedef enum logic [3:0] {
    FSM_IDLE,
    FSM_COMMAND,
    FSM_ADDRESS,     // 24-bit address phase (legacy commands)
    FSM_ADDR32,      // 32-bit address phase (BUS_WRITE/BUS_READ)
    FSM_SEL,         // 1-byte state-read selector (DBG_READ)
    FSM_FLAGS,       // 1-byte lock flags (BUS_LOCK)
    FSM_COUNT,       // 1-byte step count (DBG_STEP)
    FSM_ONE_SHOT,    // no-payload commands: issue on opcode, wait for accept
    FSM_DUMMY,       // one dummy byte ahead of a response (BUS_READ/DBG_READ/BUS_STATUS)
    FSM_READ_DATA,
    FSM_WRITE_DATA
  } spi_state_t;

  spi_state_t spi_state;

  logic [7:0]  spi_command;
  logic [31:0] spi_address;
  // The top bit shifts out as the last address bit lands: spi_address takes
  // it from spi_mosi directly, so address_shift's own top bit is never read
  // back. Sized for the wider of the two address phases (32-bit); the legacy
  // 24-bit phase uses only the low 24 bits of the same shift register.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] address_shift;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0]  address_bit_count;
  // Counts response bytes clocked out during FSM_READ_DATA for BUS_STATUS/
  // DBG_READ, purely from the RX/framing side (rx_byte_done): this only
  // decides when the *frame* is done (GRPR-SPIS-046's fixed 4 bytes), not
  // which byte spi_s_tx should be sending -- that's the TX FIFO's job now,
  // sequenced independently. Conflating the two was the bug in an earlier
  // version of this logic.
  logic [2:0]  resp_byte_count;
  logic [7:0]  dbg_sel;           // DBG_READ's selector byte
  // Only bit 0 is defined (GRPR-SPIS-047's flags byte); the rest of the byte
  // is captured for a future extension but unused today.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  dbg_flags;         // BUS_LOCK's flags byte
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  dbg_count;         // DBG_STEP's count byte
  logic        one_shot_issued;   // FSM_ONE_SHOT: request already presented once

  logic spi_sck_d;
  logic sample_edge;
  logic launch_edge;

  logic                  rx_byte_done;
  logic [DATA_WIDTH-1:0] rx_byte_data;
  logic                  rx_push_en;

  logic spi_miso_int;
  // Connected because spi_s_tx always drives it, but nothing here reads it
  // any more: request pacing keys off tx_full (the FIFO's own look-ahead),
  // not busy (the shifter's mid-byte state) -- see the note above
  // read_req_outstanding's assignment.
  /* verilator lint_off UNUSEDSIGNAL */
  logic tx_busy;
  /* verilator lint_on UNUSEDSIGNAL */
  logic tx_underrun_int;

  logic        dbg_active_ext;  // a dedicated debug opcode is currently framing
  logic        dbg_is_read;
  logic        dbg_is_write;
  logic        dbg_fixed_len;   // BUS_STATUS/DBG_READ: fixed 4-byte response
  logic [3:0]  dbg_cmd_sel;

  // BUS_READ's per-byte response, pushed into the TX FIFO as it arrives
  // (see the note above dbg_push_valid's assignment for why).
  logic                  read_push_valid;
  logic [DATA_WIDTH-1:0] read_push_byte;

  // TX FIFO push mux output: whichever of the two debug-read shapes is
  // active right now (they're mutually exclusive -- dbg_fixed_len selects
  // between them the same way it does everywhere else in this module).
  logic                  dbg_push_valid;
  logic [DATA_WIDTH-1:0] dbg_push_byte;

  // BUS_STATUS/DBG_READ response push into the TX FIFO (GRPR-SPIS-046's
  // fixed 4-byte reply) -- see the note above dbg_fixed_len_push's
  // assignment for why this goes through the FIFO rather than a dedicated
  // byte-slice mux.
  typedef enum logic [1:0] {
    PUSH_IDLE,
    PUSH_BYTE,
    PUSH_WAIT
  } fixed_len_push_state_t;

  fixed_len_push_state_t fixed_len_push_state;
  logic [31:0] fixed_len_word;
  logic [1:0]  fixed_len_push_idx;

  logic dbg_fixed_len_push;
  logic fixed_len_push_valid;
  logic [DATA_WIDTH-1:0] fixed_len_push_byte;

//------------------------------------------------------
// Clock edge selection (GRPR-SPIS-002, SPIS-SPEC-005)
//------------------------------------------------------
// Only modes 0 and 3 exist. In both the sampling edge is the one driving SCK
// to its active level and the launch edge is the other, so a single
// CPOL-selected pair covers them; CPHA is required to equal CPOL.


  always_ff @(posedge clk, negedge rst_n)
    if (~rst_n) spi_sck_d <= 1'b0;
    else        spi_sck_d <= spi_sck;

  // CPOL and CPHA both select which SCK edge samples and which launches, and
  // both do it by the same inversion: CPOL because idle-high reverses the
  // meaning of rising and falling, CPHA because it moves sampling from the
  // leading edge to the trailing one. Their effects therefore compose as an
  // XOR rather than needing two separate cases (GRPR-SPIS-002).
  logic edge_invert;
  assign edge_invert = cpol ^ cpha;

  assign sample_edge = edge_invert ? (!spi_sck &&  spi_sck_d)
                                   : ( spi_sck && !spi_sck_d);
  assign launch_edge = edge_invert ? ( spi_sck && !spi_sck_d)
                                   : (!spi_sck &&  spi_sck_d);

//------------------------------------------------------
// Command framing FSM
//------------------------------------------------------
// dbg_opcode_en is a plain parameter compare, not a register read, so it can
// gate the very first cycle of decode: GRPR-SPIS-041/-044 need the dedicated
// opcodes recognised unconditionally, with no register bit in the way.

  logic dbg_opcode_en;
  assign dbg_opcode_en = (DEBUG_PORT_EN != 0);

  assign busy = !spi_ss && (spi_state != FSM_IDLE);

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      spi_state         <= FSM_IDLE;
      spi_command       <= '0;
      spi_address       <= '0;
      address_shift     <= '0;
      address_bit_count <= '0;
      resp_byte_count   <= '0;
      dbg_sel           <= '0;
      dbg_flags         <= '0;
      dbg_count         <= '0;
      one_shot_issued   <= 1'b0;
    end
    else if (flush) begin
      spi_state         <= FSM_IDLE;
      spi_command       <= '0;
      spi_address       <= '0;
      address_shift     <= '0;
      address_bit_count <= '0;
      resp_byte_count   <= '0;
      dbg_sel           <= '0;
      dbg_flags         <= '0;
      dbg_count         <= '0;
      one_shot_issued   <= 1'b0;
    end
    else begin
      if (spi_ss) begin
        // SS high returns the decoder to idle, which is how a host
        // resynchronises after an aborted frame (GRPR-SPIS-022). It does not
        // disturb the Debug Unit's own state, including an active lock
        // (GRPR-SPIS-018).
        spi_state         <= FSM_IDLE;
        address_bit_count <= 6'd0;
        resp_byte_count   <= 3'd0;
        one_shot_issued   <= 1'b0;
      end
      else if (spi_state == FSM_IDLE) begin
        spi_state <= FSM_COMMAND;
      end

      // A read burst (legacy or BUS_READ) advances when the Debug Unit
      // accepts each request. Outside the sample_edge guard because the
      // handshake is paced by the bus, not by SCK.
      if (!spi_ss && dbg_active_ext && dbg_is_read &&
          dbg_req_valid && dbg_req_ready)
        spi_address <= spi_address + 32'd1;

      // FSM_ONE_SHOT commands (BUS_LOCK/BUS_UNLOCK/DBG_RESUME/DBG_ENABLE)
      // have no data phase to pace them, so they latch here as soon as the
      // debug port accepts, independent of sample_edge.
      if (!spi_ss && (spi_state == FSM_ONE_SHOT) &&
          dbg_req_valid && dbg_req_ready)
        one_shot_issued <= 1'b1;

      if (!spi_ss && sample_edge) begin

        if (spi_state == FSM_COMMAND) begin
          if (rx_byte_done) begin
            spi_command <= rx_byte_data;

            unique case (1'b1)
              (rx_byte_data == SPI_WRITE) || (rx_byte_data == SPI_READ) ||
              (rx_byte_data == FAST_WRITE) || (rx_byte_data == FAST_READ):
                spi_state <= FSM_ADDRESS;

              dbg_opcode_en && (rx_byte_data == OP_BUS_WRITE):
                spi_state <= FSM_ADDR32;
              dbg_opcode_en && (rx_byte_data == OP_BUS_READ):
                spi_state <= FSM_ADDR32;
              dbg_opcode_en && (rx_byte_data == OP_DBG_READ):
                spi_state <= FSM_SEL;
              dbg_opcode_en && (rx_byte_data == OP_BUS_LOCK):
                spi_state <= FSM_FLAGS;
              dbg_opcode_en && (rx_byte_data == OP_DBG_STEP):
                spi_state <= FSM_COUNT;
              dbg_opcode_en && ((rx_byte_data == OP_BUS_UNLOCK) ||
                                 (rx_byte_data == OP_DBG_RESUME) ||
                                 (rx_byte_data == OP_DBG_ENABLE)):
                spi_state <= FSM_ONE_SHOT;
              dbg_opcode_en && (rx_byte_data == OP_BUS_STATUS):
                spi_state <= FSM_DUMMY;

              default:
                // Includes the reserved 0x56 (GRPR-SPIS-048): refused by
                // never leaving FSM_IDLE for it, so it produces no request
                // and no response, exactly as an unrecognised opcode would.
                spi_state <= FSM_IDLE;
            endcase
          end
        end

        // Multi-byte data-phase bursts walk consecutive ascending addresses
        // (GRPR-SPIS-034, mirroring GRPR-DBG-012). Without this every byte
        // of a burst would target the address the frame opened with.
        else if ((spi_state == FSM_WRITE_DATA) && rx_byte_done && dbg_active_ext)
          spi_address <= spi_address + 32'd1;

        else if (spi_state == FSM_ADDRESS) begin
          address_shift <= {address_shift[30:0], spi_mosi};

          if (address_bit_count == 6'd23) begin
            spi_address       <= {8'b0, address_shift[22:0], spi_mosi};
            address_bit_count <= 6'd0;

            if (spi_command == SPI_READ || spi_command == FAST_READ)
              spi_state <= FSM_READ_DATA;
            else
              spi_state <= FSM_WRITE_DATA;
          end
          else begin
            address_bit_count <= address_bit_count + 6'd1;
          end
        end

        else if (spi_state == FSM_ADDR32) begin
          address_shift <= {address_shift[30:0], spi_mosi};

          if (address_bit_count == 6'd31) begin
            spi_address       <= {address_shift[30:0], spi_mosi};
            address_bit_count <= 6'd0;

            if (spi_command == OP_BUS_READ)
              spi_state <= FSM_DUMMY;
            else
              spi_state <= FSM_WRITE_DATA;
          end
          else begin
            address_bit_count <= address_bit_count + 6'd1;
          end
        end

        else if (spi_state == FSM_SEL) begin
          if (rx_byte_done) begin
            dbg_sel <= rx_byte_data;
            spi_state <= FSM_DUMMY;
          end
        end

        else if (spi_state == FSM_FLAGS) begin
          if (rx_byte_done) begin
            dbg_flags <= rx_byte_data;
            spi_state <= FSM_ONE_SHOT;
          end
        end

        else if (spi_state == FSM_COUNT) begin
          if (rx_byte_done) begin
            dbg_count <= rx_byte_data;
            spi_state <= FSM_ONE_SHOT;
          end
        end

        else if (spi_state == FSM_DUMMY) begin
          // One dummy byte covers the debug-port round trip (GRPR-SPIS-046)
          // before the fixed-length response phase starts.
          if (rx_byte_done)
            spi_state <= FSM_READ_DATA;
        end

        // Fixed-length responses (BUS_STATUS, DBG_READ: 4 bytes) return to
        // idle once the master has clocked the fourth response byte.
        // resp_byte_count here is purely a count of *frame* bytes clocked
        // during FSM_READ_DATA (rx_byte_done, the RX/framing side) -- it is
        // deliberately independent of how spi_s_tx internally sequences the
        // four bytes it sends, which is the TX FIFO's job (see the push FSM
        // below). An earlier version of this logic conflated the two,
        // corrupting the last byte of every fixed-length response.
        else if ((spi_state == FSM_READ_DATA) && dbg_fixed_len && rx_byte_done) begin
          if (resp_byte_count == 3'd3)
            spi_state <= FSM_IDLE;
          else
            resp_byte_count <= resp_byte_count + 3'd1;
        end
      end
    end
  end

//------------------------------------------------------
// Receive path
//------------------------------------------------------
// Payload only: the opcode identifies the frame and the address/selector/
// flags/count phases are consumed above, so only data-phase bytes reach the
// FIFO. On a debug-opcode path they are forwarded to the bus instead
// (GRPR-SPIS-032).

  assign rx_push_en = (spi_state == FSM_WRITE_DATA) && !dbg_active_ext;

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

  // Both debug-read shapes -- BUS_READ's per-byte stream and BUS_STATUS/
  // DBG_READ's fixed 4-byte reply -- push their bytes through the same TX
  // FIFO a legacy multi-byte SPI_READ already relies on, rather than the
  // ext_data/ext_valid override path spi_s_tx also offers: that path has no
  // pre-fetch buffering of its own, so pacing debug requests on it (e.g.
  // "issue the next byte once !tx_busy") leaves no margin for the
  // request/response round trip to complete before the master's next
  // sample edge, corrupting every byte after the first. The FIFO's
  // existing hold register is exactly the pre-fetch buffering that's
  // missing, so both paths are pushed through it here instead.
  assign dbg_push_valid = dbg_fixed_len_push ? fixed_len_push_valid : read_push_valid;
  assign dbg_push_byte  = dbg_fixed_len_push ? fixed_len_push_byte  : read_push_byte;

  // A debug response belongs to exactly one frame. SS high ends that frame,
  // so anything still queued in the TX FIFO or holding register is stale and
  // must not be handed to the next one: a leftover byte offsets the whole of
  // the next response by a byte position, which is how a BUS_STATUS of 0x09
  // came back as 0x04 on the second and later reads of a session while the
  // very first one was correct. Qualified by dbg_active_ext so the legacy
  // FIFO path is untouched - TXDATA a host wrote between frames is supposed
  // to survive until it is clocked out.
  logic dbg_frame_flush;
  assign dbg_frame_flush = spi_ss && dbg_active_ext;

  spi_s_tx #(
    .DATA_WIDTH (DATA_WIDTH),
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_tx (
    .clk         (clk),
    .rst_n       (rst_n),
    .flush       (flush),
    .frame_flush (dbg_frame_flush),
    .spi_ss      (spi_ss),
    .launch_edge (launch_edge),
    .miso        (spi_miso_int),
    .send_en     (spi_state == FSM_READ_DATA),
    .ext_valid   (1'b0),
    .ext_data    ('0),
    .wdata       (dbg_active_ext ? dbg_push_byte  : tx_wdata),
    .write       (dbg_active_ext ? dbg_push_valid : tx_write),
    .full        (tx_full),
    .empty       (tx_empty),
    .busy        (tx_busy),
    .underrun    (tx_underrun_int)
  );

  // ENABLE gates the wire output only; the block still frames what it sees.
  assign spi_miso = (enable && !spi_ss) ? spi_miso_int : 1'b0;

  // The debug path has no TX FIFO to run dry, so underrun is a FIFO-path
  // event only.
  assign tx_underrun = tx_underrun_int && !dbg_active_ext;

//------------------------------------------------------
// Debug transport (GRPR-SPIS-041 .. -048)
//------------------------------------------------------
// Every dedicated debug opcode maps to exactly one dbg_req_cmd. This block
// only frames and forwards -- the Debug Unit owns the bus and decides
// whether a request is permitted (GRPR-SPIS-016).
//
// dbg_active_ext covers every state a debug opcode is framing in, including
// its address/selector/flags/count phase, so the RX-path FIFO bypass
// (GRPR-SPIS-032) and the underrun exclusion above see the whole frame, not
// just its data phase.

  assign dbg_active_ext = dbg_opcode_en &&
                          ((spi_command == OP_BUS_WRITE)  ||
                           (spi_command == OP_BUS_READ)   ||
                           (spi_command == OP_BUS_STATUS) ||
                           (spi_command == OP_DBG_READ)   ||
                           (spi_command == OP_DBG_ENABLE) ||
                           (spi_command == OP_DBG_RESUME) ||
                           (spi_command == OP_DBG_STEP)   ||
                           (spi_command == OP_BUS_LOCK)   ||
                           (spi_command == OP_BUS_UNLOCK));

  assign dbg_is_read  = (spi_command == OP_BUS_READ) ||
                        (spi_command == OP_BUS_STATUS) ||
                        (spi_command == OP_DBG_READ);
  assign dbg_is_write = (spi_command == OP_BUS_WRITE);
  assign dbg_fixed_len = (spi_command == OP_BUS_STATUS) ||
                         (spi_command == OP_DBG_READ);

  always_comb begin
    case (spi_command)
      OP_BUS_WRITE:  dbg_cmd_sel = DBG_CMD_WRITE;
      OP_BUS_READ:   dbg_cmd_sel = DBG_CMD_READ;
      OP_BUS_STATUS: dbg_cmd_sel = DBG_CMD_STATUS;
      OP_DBG_READ:   dbg_cmd_sel = DBG_CMD_STATE_READ;
      OP_DBG_ENABLE: dbg_cmd_sel = DBG_CMD_DBG_ENABLE;
      OP_DBG_RESUME: dbg_cmd_sel = DBG_CMD_RESUME;
      OP_DBG_STEP:   dbg_cmd_sel = DBG_CMD_STEP;
      OP_BUS_LOCK:   dbg_cmd_sel = DBG_CMD_LOCK;
      OP_BUS_UNLOCK: dbg_cmd_sel = DBG_CMD_UNLOCK;
      default:       dbg_cmd_sel = 4'h0; // NOP; dbg_active_ext is low here anyway
    endcase
  end

  // One request per payload byte for BUS_WRITE/BUS_READ, at the
  // auto-incrementing address (GRPR-SPIS-034). The write side is qualified
  // by FSM_WRITE_DATA and rx_byte_done: without it the address phase itself
  // would issue spurious requests at whatever address had been captured so
  // far.
  //
  // BUS_STATUS/DBG_READ present one request total (their fixed 4-byte
  // response is pushed into the TX FIFO by the push FSM below once it
  // arrives). Issued as soon as FSM_DUMMY is entered -- not after the dummy
  // byte completes -- so the debug-port round trip runs concurrently with
  // the dummy byte being clocked, which is the entire reason GRPR-SPIS-046
  // specifies one: waiting until the dummy byte's last bit before issuing
  // the request leaves the response with no time to arrive before the
  // master expects the first real data bit, corrupting it.
  //
  // Gated on the push FSM still being idle (fixed_len_push_state declared
  // below, forward-referenced here as it would be with an equivalent
  // always_comb) rather than a dedicated "already issued" flag: once a
  // response has arrived and started pushing, no second request is needed
  // or wanted.
  //
  // One-shot commands (BUS_LOCK/BUS_UNLOCK/DBG_RESUME/DBG_ENABLE) present
  // their single request throughout FSM_ONE_SHOT until accepted, then hold
  // off (one_shot_issued) so SS lingering doesn't re-issue it.
  logic dbg_word_req_pending;
  assign dbg_word_req_pending = dbg_fixed_len &&
                                ((spi_state == FSM_DUMMY) || (spi_state == FSM_READ_DATA)) &&
                                (fixed_len_push_state == PUSH_IDLE);

  // read_req_outstanding paces BUS_READ's per-byte requests one at a time,
  // but -- unlike an earlier version of this logic -- does NOT wait for
  // spi_s_tx to finish shifting the previous byte before requesting the
  // next one. Gating on !tx_busy left the debug-port round trip for byte
  // N+1 starting only after byte N's 8 bits were already fully on the
  // wire, with no margin before the master's next sample edge; SCK keeps
  // running on its own schedule regardless of whether the response is
  // ready (GRPR-SPIS-034's "the bus paces reads rather than SCK" only
  // works if this side actually gets ahead of the wire).
  //
  // read_lookahead caps how far ahead of the wire this is allowed to get:
  // it counts accepted-but-not-yet-wire-consumed bytes (incremented on
  // acceptance, decremented on the rx_byte_done that marks the master
  // clocking a byte off in FSM_READ_DATA), and a new request is issued
  // only while it is below READ_LOOKAHEAD_MAX. Gating on !tx_full alone
  // (an earlier version of this logic) had no such cap: the FIFO has room
  // for several bytes, so it kept accepting requests every cycle until
  // full, racing arbitrarily far ahead of the wire and scrambling the
  // address sequence and TX ordering for anything past the first byte.
  //
  // A cap of exactly 1 (an earlier version of *this* logic) still wasn't
  // enough: the request/response/FIFO-write/fifo_read/hold_valid chain
  // this block and spi_s_tx's hold register together need is four cycles
  // deep, longer than the one-byte-period gap a cap of 1 leaves between
  // "wire consumes byte N" and "wire needs byte N+1", so the load for
  // byte N+1 was still landing after the master's first sample of it. Two
  // bytes of look-ahead gives that pipeline a full extra byte period to
  // drain into before the wire catches up.
  localparam logic [1:0] READ_LOOKAHEAD_MAX = 2'd2;

  logic read_req_outstanding;
  logic [1:0] read_lookahead;

  assign dbg_req_valid = !spi_ss && dbg_active_ext &&
                         ((dbg_is_write && (spi_state == FSM_WRITE_DATA) && rx_byte_done) ||
                          // BUS_READ's first request is issuable from FSM_DUMMY
                          // onward, same as the fixed-length path and for the
                          // same reason (GRPR-SPIS-046): starting only at
                          // FSM_READ_DATA left the FIFO's own push latency
                          // (write -> fifo_read -> fifo_read_r -> hold_valid,
                          // four cycles before spi_s_tx can even load) with no
                          // margin at all before the master's first sample.
                          //
                          // read_req_outstanding gates one request at a time,
                          // matching the debug port's own single-outstanding-
                          // request contract (GRPR-DBG-005); read_lookahead
                          // additionally bounds how many *responses* may sit
                          // ahead of the wire (see the note above its
                          // declaration) -- together they let request N+2 be
                          // issued as soon as request N+1 is accepted, while
                          // N+1's response is still in flight.
                          (!dbg_fixed_len && dbg_is_read &&
                           ((spi_state == FSM_DUMMY) || (spi_state == FSM_READ_DATA)) &&
                           !tx_full && !read_req_outstanding &&
                           (read_lookahead < READ_LOOKAHEAD_MAX)) ||
                          (dbg_fixed_len && dbg_word_req_pending) ||
                          ((spi_state == FSM_ONE_SHOT) && !one_shot_issued));

  assign dbg_req_cmd   = dbg_cmd_sel;
  assign dbg_req_addr  = (spi_command == OP_DBG_READ) ? {24'b0, dbg_sel} : spi_address;
  assign dbg_req_wdata = (spi_command == OP_BUS_LOCK)  ? {23'b0, 1'b1, 7'b0, dbg_flags[0]} :
                         (spi_command == OP_DBG_STEP)  ? {24'b0, dbg_count} :
                         (spi_command == OP_BUS_WRITE) ? {24'b0, rx_byte_data} :
                         32'b0;
  assign dbg_req_size  = 2'd0;
  assign dbg_rsp_ready = dbg_active_ext;

  // A read response supplies the next byte spi_s_tx sends, via the TX FIFO
  // (read_push_valid/read_push_byte below) rather than a dedicated
  // ext_data/ext_valid override -- the same reasoning as the fixed-length
  // push: the FIFO already solves "pace bytes onto the wire as they become
  // available" correctly, and reusing it here is what gives BUS_READ its
  // two-byte look-ahead (READ_LOOKAHEAD_MAX) instead of reinventing
  // pre-fetch buffering.
  // An error is reported through IRQ_STATUS rather than stalling the wire:
  // the host is clocking SCK and cannot be held off, so the transfer
  // completes with whatever the bus returned (GRPR-SPIS-033) -- an errored
  // byte simply isn't pushed, so spi_s_tx re-sends nothing conjured for it.
  assign dbg_err_evt = dbg_rsp_valid && dbg_rsp_ready && dbg_rsp_err;

  assign read_push_valid = dbg_rsp_valid && dbg_rsp_ready && !dbg_rsp_err &&
                           !dbg_fixed_len && dbg_is_read;
  assign read_push_byte  = dbg_rsp_rdata[7:0];

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      read_req_outstanding <= 1'b0;
      read_lookahead       <= 2'd0;
    end
    else if (flush || spi_ss) begin
      read_req_outstanding <= 1'b0;
      read_lookahead       <= 2'd0;
    end
    else begin
      // read_lookahead_inc/dec can both be true the same cycle (a request
      // accepted and, independently, the wire consuming a byte); adding
      // both terms to the same next-value expression nets them to zero
      // together rather than letting one "if" silently overwrite the
      // other's effect, which separate non-blocking assigns would do.
      logic req_accepted;
      logic byte_consumed;
      req_accepted  = !dbg_fixed_len && dbg_is_read && dbg_req_valid && dbg_req_ready;
      byte_consumed = !dbg_fixed_len && dbg_is_read &&
                      (spi_state == FSM_READ_DATA) && rx_byte_done;

      if (req_accepted)
        read_req_outstanding <= 1'b1;

      if (dbg_rsp_valid && dbg_rsp_ready && !dbg_fixed_len)
        read_req_outstanding <= 1'b0;

      case ({req_accepted, byte_consumed})
        2'b10:   read_lookahead <= read_lookahead + 2'd1;
        2'b01:   read_lookahead <= read_lookahead - 2'd1;
        default: read_lookahead <= read_lookahead; // 00: no change, 11: nets to zero
      endcase
    end
  end

  // BUS_STATUS/DBG_READ's fixed 4-byte response is pushed into the TX FIFO
  // as four ordinary bytes, MSB-first, rather than driving a dedicated
  // byte-slice mux like the one this replaced: that mux needed to know
  // exactly which cycle spi_s_tx's internal shifter had gone idle and was
  // ready for the *next* byte, and a hand-rolled edge detector on spi_s_tx's
  // busy output got that wrong for the last of the four bytes, corrupting
  // it. The FIFO already solves exactly this sequencing problem correctly
  // -- it's what a legacy multi-byte SPI_READ burst relies on -- so pushing
  // through it here reuses proven logic instead of re-deriving it.
  //
  // fixed_len_push_state !=IDLE claims the wdata/write mux above away from
  // the AHB-side TXDATA write for the cycles it needs; those don't overlap
  // in practice (the wire is mid-frame on a debug opcode whenever this
  // runs), but the mux still has to pick a side explicitly.
  assign dbg_fixed_len_push   = (fixed_len_push_state != PUSH_IDLE);
  assign fixed_len_push_valid = (fixed_len_push_state == PUSH_BYTE) && !tx_full;

  always_comb begin
    case (fixed_len_push_idx)
      2'd0:    fixed_len_push_byte = fixed_len_word[31:24];
      2'd1:    fixed_len_push_byte = fixed_len_word[23:16];
      2'd2:    fixed_len_push_byte = fixed_len_word[15:8];
      default: fixed_len_push_byte = fixed_len_word[7:0];
    endcase
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      fixed_len_push_state <= PUSH_IDLE;
      fixed_len_word       <= '0;
      fixed_len_push_idx   <= '0;
    end
    else if (flush || spi_ss) begin
      fixed_len_push_state <= PUSH_IDLE;
      fixed_len_word       <= '0;
      fixed_len_push_idx   <= '0;
    end
    else begin
      case (fixed_len_push_state)
        PUSH_IDLE: begin
          if (dbg_rsp_valid && dbg_rsp_ready && !dbg_rsp_err && dbg_fixed_len) begin
            fixed_len_word       <= dbg_rsp_rdata;
            fixed_len_push_idx   <= 2'd0;
            fixed_len_push_state <= PUSH_BYTE;
          end
        end

        PUSH_BYTE: begin
          // fixed_len_push_valid already excludes !tx_full, so reaching
          // here with the FIFO full simply waits; small_sync_fifo would
          // otherwise silently overwrite its oldest entry on an
          // unqualified push (SPIS-SPEC-013), which fixed_len_push_valid's
          // !tx_full term is what avoids.
          if (fixed_len_push_valid) begin
            if (fixed_len_push_idx == 2'd3)
              fixed_len_push_state <= PUSH_WAIT;
            else
              fixed_len_push_idx <= fixed_len_push_idx + 2'd1;
          end
        end

        PUSH_WAIT: begin
          // All four bytes are queued; nothing left to drive into the
          // FIFO. Stay here (not IDLE) so a lingering dbg_rsp_valid pulse
          // from the far end can't be mistaken for a second response.
        end

        default: fixed_len_push_state <= PUSH_IDLE;
      endcase
    end
  end

endmodule
