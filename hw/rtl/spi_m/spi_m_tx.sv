
// SPI master transmit path: phase sequencer (CMD -> ADDR -> DUMMY -> DATA),
// SCK generation and the MOSI shift register.
//
// Timing model
// ------------
// spi_clk_en pulses once per SCK *half* period; spi_sck toggles on it. Two
// derived pulses name the edges:
//
//   sck_launch  - the edge that changes MOSI   (leading edge  in CPHA=0,
//                                               trailing edge in CPHA=1)
//   sck_sample  - the edge the slave samples on (the other one)
//
// A bit is only retired on sck_sample, so every byte occupies exactly 8 full
// SCK periods (GRPR-SPIM-016) and a phase ends only after the final bit's
// sampling edge (GRPR-SPIM-014). All phase counters advance on sck_sample and
// nothing advances on the bare system clock.

module spi_m_tx #(
  parameter int DATA_WIDTH = 8,
  parameter int FIFO_DEPTH = 4

) (
  input  logic                    clk,
  input  logic                    rst_n,

  input  logic                    spi_clk_en,

  // Control signals
  input  logic                    enable,
  input  logic                    start,

  input  logic                    cpol,
  input  logic                    cpha,

  input  logic [7:0]              opcode,
  input  logic                    cmd_en,

  input  logic                    addr_en,
  input  logic [1:0]              addr_bytes,
  input  logic [31:0]             addr,

  input  logic                    data_en,
  input  logic                    dir,          // 0 = write (drive MOSI), 1 = read
  input  logic [4:0]              dummy_cycles,
  input  logic [7:0]              data_len,     // bytes minus 1

  output logic                    busy,
  output logic                    done,

  // Data-phase handshake to the RX path
  output logic                    data_phase,
  output logic                    sck_sample,
  output logic                    sck_launch,

  input  logic                    flush_tx_fifo,
  input  logic [DATA_WIDTH-1:0]   tx_data,
  input  logic                    tx_write,
  output logic                    tx_full,
  output logic                    tx_empty,
  output logic                    tx_underrun,

  // SPI interface
  output logic                    spi_mosi,
  output logic                    spi_sck,
  output logic                    spi_cs_n
);

  localparam int SHIFT_CTR_W = $clog2(DATA_WIDTH) + 1;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_CMD,
    ST_ADDR,
    ST_DUMMY,
    ST_DATA,
    ST_DONE
  } e_state;

  e_state                  state;
  e_state                  next_state;

  logic                    shift_load;
  logic                    shift_bit;
  logic                    shift_out;
  logic [DATA_WIDTH-1:0]   shift_data;
  logic [SHIFT_CTR_W-1:0]  bit_count;
  logic                    last_bit;

  logic                    fifo_read;
  logic [DATA_WIDTH-1:0]   fifo_rdata;
  logic                    tx_stall;
  logic                    data_load;

  logic [2:0]              addr_count;
  logic [7:0]              data_count;
  logic [4:0]              dummy_count;
  logic [31:0]             addr_shift;

  logic                    phase_last;    // final SCK period of the current phase
  logic                    advance;       // retire a bit this cycle


  logic                    sck_tick;
  logic                    edge_to_active;   // this tick drives SCK idle -> active
  logic                    edge_to_idle;     // this tick drives SCK active -> idle


  // Load on entry to a shifting phase, and between bytes of ADDR/DATA.
  logic                    enter_cmd;
  logic                    enter_addr; 
  logic                    enter_data; 
  logic                    next_byte;

  logic [DATA_WIDTH-1:0]   tx_hold;
  logic                    tx_hold_valid;
  logic                    fifo_read_r;


  // ---------------------------------------------------------------------------
  // SCK generation
  // ---------------------------------------------------------------------------
  // The divider free-runs, so hold SCK at its idle level and swallow ticks
  // while idle; the first toggle after CS_N falls is then a full half period
  // after the transfer starts, giving deterministic CS setup (SPIM-ISSUE-025).

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      spi_sck <= 1'b0;
    end else if (state == ST_IDLE || state == ST_DONE) begin
      spi_sck <= cpol;
    end else if (spi_clk_en && !tx_stall) begin
      spi_sck <= ~spi_sck;
    end
  end

  // Which physical edge is which, per CPHA. In mode 0 (CPHA=0) MOSI is
  // launched on the trailing edge (back to idle) and sampled on the leading
  // edge; in mode 3 (CPHA=1) it is the other way round.
  //
  // spi_sck is registered, so on the tick that toggles it the OLD level is
  // still visible here. The tick that drives SCK to its active level is
  // therefore the one seen while spi_sck still reads the idle level (cpol),
  // and the pulse lands on the clock edge that performs the transition.

  assign sck_tick       = spi_clk_en && !tx_stall &&
                          (state != ST_IDLE) && (state != ST_DONE);

  // These pulse in the cycle where SCK *holds* the named level, one system
  // clock after the edge that produced it. Sampling is therefore aligned with
  // the level a slave sees, not with the transition itself.
  assign edge_to_active = sck_tick && (spi_sck != cpol);
  assign edge_to_idle   = sck_tick && (spi_sck == cpol);

  assign sck_sample = cpha ? edge_to_idle   : edge_to_active;
  assign sck_launch = cpha ? edge_to_active : edge_to_idle;

  assign advance = sck_sample && (state != ST_IDLE) && (state != ST_DONE);

  // ---------------------------------------------------------------------------
  // TX FIFO
  // ---------------------------------------------------------------------------
  // See the holding-register comment below for how the FIFO's one-cycle read
  // latency is absorbed.

  small_sync_fifo #(
    .DATA_WIDTH(DATA_WIDTH),
    .FIFO_DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk    (clk),
    .rst_n  (rst_n),
    .flush  (flush_tx_fifo),
    .wdata  (tx_data),
    .write  (tx_write),
    .read   (fifo_read),
    .rdata  (fifo_rdata),
    .full   (tx_full),
    .empty  (tx_empty)
  );

  // The FIFO registers rdata, so a pop is only readable on the NEXT clock.
  // A one-entry holding register absorbs that latency: tx_hold always has the
  // byte the next load needs, and the FIFO is popped to refill it whenever it
  // is empty and the FIFO is not. The load then never reads a same-cycle pop,
  // which is what made the first data byte 0x00 (SPIM-ISSUE-010).


  // Refill whenever the holding register has room and the FIFO has a byte.
  // Deliberately independent of data_load and of tx_stall: gating the refill
  // on the load would deadlock, since the stall that the refill clears is
  // what blocks the load in the first place.
  assign fifo_read = data_en && !dir && !tx_empty &&
                     !fifo_read_r && !tx_hold_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_hold       <= '0;
      tx_hold_valid <= 1'b0;
      fifo_read_r   <= 1'b0;
    end else if (flush_tx_fifo) begin
      tx_hold       <= '0;
      tx_hold_valid <= 1'b0;
      fifo_read_r   <= 1'b0;
    end else begin
      fifo_read_r <= fifo_read;

      // A pop issued last cycle presents its data now.
      if (fifo_read_r) begin
        tx_hold       <= fifo_rdata;
        tx_hold_valid <= 1'b1;
      end else if (data_load) begin
        tx_hold_valid <= 1'b0;
      end
    end
  end

  // Stall SCK if the data phase needs a byte the CPU has not supplied yet
  // (SPIM-SPEC-009). CS_N stays low and the transfer resumes on the next
  // DATA write.
  // Only stall when a byte is genuinely still needed. Once the final byte has
  // been loaded into the shift register the holding register is legitimately
  // empty, and stalling there would hang the last byte of every transfer.
  assign tx_stall    = (state == ST_DATA) && !dir && !tx_hold_valid &&
                       (data_count != data_len);
  assign tx_underrun = tx_stall;

  // ---------------------------------------------------------------------------
  // Shift register and bit counter
  // ---------------------------------------------------------------------------

  shift_reg #(
    .WIDTH          (DATA_WIDTH),
    .LSB_FIRST      (0),          // SPI is MSB first -- GRPR-SPIM-003
    // Combinational output: the loaded MSB reaches MOSI in the same cycle as
    // the load, so the first bit is stable before the first sampling edge.
    .REGISTERED_OUT (0)
  ) u_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),
    .shift      (shift_bit),
    .load       (shift_load),
    .load_value (shift_data),
    .in         (1'b0),
    /* verilator lint_off PINCONNECTEMPTY */
    .value_out  (),
    /* verilator lint_on PINCONNECTEMPTY */
    .out        (shift_out)
  );

  // The load presents bit 7 on MOSI, so the first launch edge of a byte must
  // not shift -- it would consume that bit before the slave ever sampled it.
  // Shifting starts once the first bit has been sampled, i.e. from
  // bit_count != 0, and stops after the last bit is retired.
  assign shift_bit = sck_launch && (bit_count != '0) &&
                     (state == ST_CMD || state == ST_ADDR || state == ST_DATA);

  assign last_bit = (bit_count == SHIFT_CTR_W'(DATA_WIDTH - 1));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      bit_count <= '0;
    else if (shift_load)
      bit_count <= '0;
    else if (advance && (state == ST_CMD || state == ST_ADDR || state == ST_DATA))
      bit_count <= last_bit ? '0 : (bit_count + 1'b1);
  end

  // Source of each byte. The address phase sends the LOW-order ADDR_BYTES+1
  // bytes, MSB-first within that field (SPIM-ISSUE-012): addr_shift is
  // pre-aligned at start so the byte to send is always [31:24].
  // Keyed on next_state, not state: shift_load is asserted on the cycle that
  // *enters* a phase, while state still holds the previous one.
  always_comb begin
    unique case (next_state)
      ST_CMD:  shift_data = opcode;
      // At a mid-phase byte boundary addr_shift has not yet shifted (it does
      // so on this same clock edge), so take the next byte directly.
      ST_ADDR: shift_data = next_byte ? addr_shift[23:16] : addr_shift[31:24];
      ST_DATA: shift_data = tx_hold;
      default: shift_data = '0;
    endcase
  end

  assign enter_cmd  = (state != ST_CMD)  && (next_state == ST_CMD);
  assign enter_addr = (state != ST_ADDR) && (next_state == ST_ADDR);
  assign enter_data = (state != ST_DATA) && (next_state == ST_DATA);

  // Mid-phase byte boundary: retiring the last bit with more bytes to come.
  assign next_byte = advance && last_bit &&
                     ((state == ST_ADDR && (addr_count != {1'b0, addr_bytes})) ||
                      (state == ST_DATA && (data_count != data_len)));

  assign shift_load = enter_cmd || enter_addr || enter_data || next_byte;

  // The loads that consume a byte from the TX FIFO.
  assign data_load  = enter_data || (next_byte && (state == ST_DATA));

  // ---------------------------------------------------------------------------
  // Phase sequencer
  // ---------------------------------------------------------------------------
  // phase_last is true on the SCK period that completes the current phase.

  always_comb begin
    unique case (state)
      ST_CMD:   phase_last = last_bit;
      ST_ADDR:  phase_last = last_bit && (addr_count == {1'b0, addr_bytes});
      ST_DUMMY: phase_last = (dummy_count == dummy_cycles - 5'd1);
      ST_DATA:  phase_last = last_bit && (data_count == data_len);
      default:  phase_last = 1'b0;
    endcase
  end

  // The phase that follows whichever one is finishing.
  function automatic e_state after_cmd();
    if (addr_en)             return ST_ADDR;
    else if (dummy_cycles != 0) return ST_DUMMY;
    else if (data_en)        return ST_DATA;
    else                     return ST_DONE;
  endfunction

  function automatic e_state after_addr();
    if (dummy_cycles != 0)   return ST_DUMMY;
    else if (data_en)        return ST_DATA;
    else                     return ST_DONE;
  endfunction

  always_comb begin : next_state_logic
    next_state = state;

    unique case (state)
      ST_IDLE: begin
        if (start && enable) begin
          if (cmd_en)                 next_state = ST_CMD;
          else if (addr_en)           next_state = ST_ADDR;
          else if (dummy_cycles != 0) next_state = ST_DUMMY;
          else if (data_en)           next_state = ST_DATA;
          else                        next_state = ST_DONE;
        end
      end

      ST_CMD:   if (advance && phase_last) next_state = after_cmd();
      ST_ADDR:  if (advance && phase_last) next_state = after_addr();

      // Dummy cycles are counted in whole SCK periods (SPIM-ISSUE-006).
      ST_DUMMY: if (advance && phase_last) next_state = data_en ? ST_DATA : ST_DONE;

      ST_DATA:  if (advance && phase_last) next_state = ST_DONE;

      ST_DONE:  next_state = ST_IDLE;

      default:  next_state = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= ST_IDLE;
      addr_count  <= '0;
      data_count  <= '0;
      dummy_count <= '0;
      addr_shift  <= '0;
    end else begin
      state <= next_state;

      if (state == ST_IDLE) begin
        addr_count  <= '0;
        data_count  <= '0;
        dummy_count <= '0;
        // Left-align the low-order (addr_bytes+1) bytes so the first byte to
        // transmit sits in [31:24].
        if (start) begin
          unique case (addr_bytes)
            2'd0: addr_shift <= {addr[7:0],  24'h0};
            2'd1: addr_shift <= {addr[15:0], 16'h0};
            2'd2: addr_shift <= {addr[23:0],  8'h0};
            2'd3: addr_shift <= addr;
          endcase
        end
      end else if (advance) begin
        if (state == ST_ADDR && last_bit) begin
          addr_count <= addr_count + 1'b1;
          addr_shift <= {addr_shift[23:0], 8'h00};
        end

        if (state == ST_DUMMY)
          dummy_count <= dummy_count + 1'b1;

        if (state == ST_DATA && last_bit)
          data_count <= data_count + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  
  // Drive MOSI only while actually transmitting; hold low during a read data
  // phase and the dummy phase (SPIM-ISSUE-009).
  assign spi_mosi = (state == ST_CMD || state == ST_ADDR ||
                     (state == ST_DATA && !dir)) ? shift_out : 1'b0;

  // CS_N covers the whole transfer including ST_DONE, which gives one SCK
  // half period of hold after the last sampling edge (SPIM-ISSUE-025).
  assign spi_cs_n = (state == ST_IDLE);

  assign busy       = (state != ST_IDLE);
  assign done       = (state == ST_DONE);
  assign data_phase = (state == ST_DATA);

endmodule
