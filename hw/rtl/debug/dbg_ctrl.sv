// AHB Debug Unit
//
// Specification: docs/hardware/design/blocks/Debug Unit.md
//
// Sits inside cpu_ss, beside the CPU rather than in series with it
// (GRPR-DBG-001). Owns no AHB port of any kind (GRPR-DBG-002): it drives a
// native-memory-interface request into cpu_ss's ownership mux and reaches
// every target that mux already reaches - ROM, RAM, the bank-switch
// register, and the AHB peripheral aperture - without a second address
// decode of its own.
//
// CPU Debug Access (STATE_READ / STEP / RESUME) is trace-based: PC and
// retirement come from picorv32's trace_valid/trace_data, which cpu_ss now
// enables unconditionally. Arbitrary GPR-by-index read (STATE_READ selectors
// 0x10-0x1F, DBGSEL/DBGREG) needs a register-file read port picorv32 does
// not yet expose - those selectors are refused with dbg_rsp_err until that
// fork lands. See Debug Unit.md GRPR-DBG-INFO-003 and this repo's open items.

module dbg_ctrl #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
)(
  input  logic                     clk,
  input  logic                     rst_n,

  // Debug port (GRPR-DBG-042) - the transport-facing interface.
  input  logic                     dbg_req_valid,
  output logic                     dbg_req_ready,
  input  logic [3:0]               dbg_req_cmd,
  input  logic [ADDR_WIDTH-1:0]    dbg_req_addr,
  input  logic [DATA_WIDTH-1:0]    dbg_req_wdata,
  input  logic [1:0]               dbg_req_size,
  output logic                     dbg_rsp_valid,
  input  logic                     dbg_rsp_ready,
  output logic [DATA_WIDTH-1:0]    dbg_rsp_rdata,
  output logic                     dbg_rsp_err,

  // Lock-active indication (GRPR-DBG-044), brought to the cpu_ss boundary.
  output logic                     dbg_lock_active,

  // Bus request into cpu_ss's ownership mux (GRPR-DBG-008).
  output logic                     dbg_own,
  output logic                     dbg_req,
  output logic                     dbg_write,
  output logic [ADDR_WIDTH-1:0]    dbg_addr,
  output logic [DATA_WIDTH-1:0]    dbg_wdata,
  output logic [3:0]               dbg_wstrb,
  input  logic                     dbg_ready,
  input  logic [DATA_WIDTH-1:0]    dbg_rdata,
  input  logic                     dbg_bus_error,

  // CPU control and observation.
  output logic                     cpu_freeze,
  output logic                     cpu_rst_req,
  input  logic                     cpu_trace_valid,
  input  logic [35:0]              cpu_trace_data
);

  // --- Command encodings (Debug Unit.md § Debug Port Commands) ------------

  localparam logic [3:0] CMD_NOP        = 4'h0;
  localparam logic [3:0] CMD_LOCK       = 4'h1;
  localparam logic [3:0] CMD_UNLOCK     = 4'h2;
  localparam logic [3:0] CMD_READ       = 4'h3;
  localparam logic [3:0] CMD_WRITE      = 4'h4;
  localparam logic [3:0] CMD_STATUS     = 4'h5;
  localparam logic [3:0] CMD_STATE_READ = 4'h6;
  localparam logic [3:0] CMD_STEP       = 4'h7;
  localparam logic [3:0] CMD_RESUME     = 4'h8;
  localparam logic [3:0] CMD_REG_READ   = 4'hA;
  localparam logic [3:0] CMD_REG_WRITE  = 4'hB;
  localparam logic [3:0] CMD_DBG_ENABLE = 4'hC;

  // --- Register offsets (Debug Unit.md § Register Map) ---------------------

  localparam logic [7:0] REG_CTRL       = 8'h00;
  localparam logic [7:0] REG_STATUS     = 8'h04;
  localparam logic [7:0] REG_BUSADDR    = 8'h08;
  localparam logic [7:0] REG_BUSDATA    = 8'h0C;
  localparam logic [7:0] REG_BUSERR     = 8'h10;
  localparam logic [7:0] REG_DBGPC      = 8'h14;
  localparam logic [7:0] REG_DBGTRACE   = 8'h18;
  localparam logic [7:0] REG_DBGTRACEH  = 8'h1C;
  localparam logic [7:0] REG_DBGREG     = 8'h20;
  localparam logic [7:0] REG_DBGSEL     = 8'h24;

  // State-read selectors (§ State Read Selectors). Selectors 0x10-0x1F
  // (GPR-by-index) are not yet supported - see the module header comment.
  // SEL_PC is named for documentation but never matched: there is no
  // trace-derived PC (see the note above the trace-capture block below), so
  // it is always refused rather than reused for an unrelated purpose.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [7:0] SEL_PC          = 8'h00;
  /* verilator lint_on UNUSEDPARAM */
  localparam logic [7:0] SEL_TRACE_LOW   = 8'h01;
  localparam logic [7:0] SEL_TRACE_FLAGS = 8'h02;

  // --- Register file --------------------------------------------------------

  // CTRL - 0x00
  logic ctrl_lock_en;
  logic ctrl_lock_mode;
  logic ctrl_dbg_en;

  // STATUS - 0x04
  logic status_lock_active;
  logic status_lock_mode_act;
  logic status_lock_pending;
  logic status_cpu_halted;
  logic status_rejected;
  logic status_bus_err;
  logic status_step_done;

  // Capture registers
  logic [31:0] busaddr_r;
  logic [31:0] busdata_r;
  logic        buserr_valid;
  logic        buserr_cause;   // 0 = AHB error response, 1 = unmapped address
  logic        buserr_write;

  // Trace mirror. There is no DBGPC register/flop here - see the note above
  // the trace-capture block below for why SEL_PC/REG_DBGPC are refused
  // instead of implemented against trace data.
  logic [31:0] dbgtrace_r;
  logic [3:0]  dbgtrace_flags_r;
  logic        dbgtrace_valid_r;

  // DBGSEL - 0x24 (writable; DBGREG readback for 0x10-0x1F is not yet
  // implemented).
  logic [4:0] dbgsel_r;

  assign dbg_lock_active = status_lock_active;
  assign dbg_own         = status_lock_active;

  // --- Step counter ----------------------------------------------------------

  logic [7:0] step_count_r;      // instructions remaining in the current step
  logic       stepping_r;        // a step is in progress

  // --- Request handshake / latch --------------------------------------------
  //
  // One outstanding request at a time (GRPR-DBG-005). Accept into a latch on
  // dbg_req_ready, process, then hold the response until dbg_rsp_ready.

  logic         req_pending_r;
  logic [3:0]   req_cmd_r;
  logic [31:0]  req_addr_r;
  logic [31:0]  req_wdata_r;
  logic [1:0]   req_size_r;

  logic         rsp_valid_r;
  logic [31:0]  rsp_rdata_r;
  logic         rsp_err_r;

  assign dbg_req_ready = !req_pending_r && !rsp_valid_r;
  assign dbg_rsp_valid = rsp_valid_r;
  assign dbg_rsp_rdata = rsp_rdata_r;
  assign dbg_rsp_err   = rsp_err_r;

  // --- Refusal decode (combinational, off the latched request) --------------
  //
  // Declared ahead of its consumers: it gates whether a bus transfer starts
  // this cycle and what the response that follows carries.

  logic refuse;
  logic reg_write_readonly;
  logic reg_offset_valid;
  logic sel_valid;

  always_comb begin
    reg_offset_valid = (req_addr_r[7:0] == REG_CTRL)     ||
                        (req_addr_r[7:0] == REG_STATUS)   ||
                        (req_addr_r[7:0] == REG_BUSADDR)  ||
                        (req_addr_r[7:0] == REG_BUSDATA)  ||
                        (req_addr_r[7:0] == REG_BUSERR)   ||
                        (req_addr_r[7:0] == REG_DBGPC)    ||
                        (req_addr_r[7:0] == REG_DBGTRACE) ||
                        (req_addr_r[7:0] == REG_DBGTRACEH)||
                        (req_addr_r[7:0] == REG_DBGREG)   ||
                        (req_addr_r[7:0] == REG_DBGSEL);

    reg_write_readonly = (req_addr_r[7:0] == REG_BUSADDR)  ||
                          (req_addr_r[7:0] == REG_BUSDATA)  ||
                          (req_addr_r[7:0] == REG_BUSERR)   ||
                          (req_addr_r[7:0] == REG_DBGPC)    ||
                          (req_addr_r[7:0] == REG_DBGTRACE) ||
                          (req_addr_r[7:0] == REG_DBGTRACEH)||
                          (req_addr_r[7:0] == REG_DBGREG);

    // SEL_PC is deliberately excluded: there is no trace-derived PC (see the
    // note above the trace-capture block), so STATE_READ of the PC selector
    // is refused rather than returning a value that looks valid but is not.
    sel_valid = (req_addr_r[7:0] == SEL_TRACE_LOW) ||
                (req_addr_r[7:0] == SEL_TRACE_FLAGS);

    case (req_cmd_r)
      CMD_LOCK:             refuse = !ctrl_lock_en || status_lock_active;
      CMD_READ, CMD_WRITE:  refuse = 1'b0;  // bus errors are reported, not refused
      CMD_STATE_READ:       refuse = !ctrl_dbg_en || !status_cpu_halted || !sel_valid;
      CMD_STEP, CMD_RESUME: refuse = !ctrl_dbg_en || !status_cpu_halted;
      CMD_REG_READ:         refuse = !reg_offset_valid;
      CMD_REG_WRITE:        refuse = !reg_offset_valid || reg_write_readonly;
      CMD_STATUS, CMD_UNLOCK, CMD_NOP, CMD_DBG_ENABLE: refuse = 1'b0;
      default:              refuse = 1'b1;   // reserved: 0x9, 0xD-0xF
    endcase
  end

  // --- Bus-mastering FSM -----------------------------------------------------
  //
  // dbg_own tracks LOCK_ACTIVE for the whole lock (GRPR-DBG-043 needs
  // cpu_mem_ready gated for the entire lock, not just mid-beat). This small
  // FSM only sequences the read/write strobes and address/data of one
  // debug-sourced transfer within that window.

  typedef enum logic {
    BUS_IDLE,
    BUS_OWNED
  } bus_state_e;

  bus_state_e  bus_state_r;
  logic        bus_write_r;
  logic [31:0] bus_addr_r;
  logic [31:0] bus_wdata_r;
  logic [3:0]  bus_wstrb_r;
  logic        bus_start;

  assign bus_start = req_pending_r && !refuse &&
                      (req_cmd_r == CMD_READ || req_cmd_r == CMD_WRITE) &&
                      bus_state_r == BUS_IDLE && !rsp_valid_r;

  always_comb begin
    dbg_req   = (bus_state_r == BUS_OWNED);
    dbg_write = bus_write_r;
    dbg_addr  = bus_addr_r;
    dbg_wdata = bus_wdata_r;
    dbg_wstrb = bus_wstrb_r;
  end

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      bus_state_r <= BUS_IDLE;
      bus_write_r <= 1'b0;
      bus_addr_r  <= '0;
      bus_wdata_r <= '0;
      bus_wstrb_r <= '0;
    end else begin
      case (bus_state_r)
        BUS_IDLE: begin
          if (bus_start) begin
            bus_state_r <= BUS_OWNED;
            bus_write_r <= (req_cmd_r == CMD_WRITE);
            bus_addr_r  <= req_addr_r;
            // wdata must land in the same byte lane(s) bus_wstrb_r marks
            // active: the memory side (ram_ss.sv's gen_sram lanes) reads
            // wdata[i*8 +: 8] wherever wstrb[i] is set, not always
            // wdata[7:0]. req_wdata_r arrives as a plain byte/halfword
            // value in the low bits (the debug port's own convention,
            // matching req_size_r), so it has to be shifted left into the
            // lane(s) the address selects, the same shift bus_wstrb_r
            // itself uses -- leaving it unshifted silently wrote every
            // non-lane-0 byte as zero.
            case (req_size_r)
              2'd0: begin                                                 // byte
                bus_wstrb_r <= 4'b0001 << req_addr_r[1:0];
                case (req_addr_r[1:0])
                  2'd0:    bus_wdata_r <= {24'b0, req_wdata_r[7:0]};
                  2'd1:    bus_wdata_r <= {16'b0, req_wdata_r[7:0],  8'b0};
                  2'd2:    bus_wdata_r <= {8'b0,  req_wdata_r[7:0], 16'b0};
                  default: bus_wdata_r <= {       req_wdata_r[7:0], 24'b0};
                endcase
              end
              2'd1: begin                                                 // halfword
                bus_wstrb_r <= req_addr_r[1] ? 4'b1100 : 4'b0011;
                bus_wdata_r <= req_addr_r[1] ? {req_wdata_r[15:0], 16'b0} : {16'b0, req_wdata_r[15:0]};
              end
              default: begin                                              // word
                bus_wstrb_r <= 4'b1111;
                bus_wdata_r <= req_wdata_r;
              end
            endcase
          end
        end
        BUS_OWNED: begin
          if (dbg_ready) begin
            bus_state_r <= BUS_IDLE;
          end
        end
        default: bus_state_r <= BUS_IDLE;
      endcase
    end
  end

  // --- CPU control (cpu_freeze / cpu_rst_req) - single driving process ------
  //
  // Consolidated into one process: lock entry/exit, resume, and stepping all
  // touch cpu_freeze, and a signal may have only one driver.

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      cpu_freeze  <= 1'b0;
      cpu_rst_req <= 1'b0;
    end else begin
      // Lock entry: bring up the requested flavour.
      if (status_lock_pending) begin
        if (status_lock_mode_act) begin
          cpu_rst_req <= 1'b1;
        end else begin
          cpu_freeze  <= 1'b1;
        end
      end

      // Lock exit (UNLOCK): drop both.
      if (req_pending_r && req_cmd_r == CMD_UNLOCK && !refuse &&
          bus_state_r == BUS_IDLE) begin
        cpu_freeze  <= 1'b0;
        cpu_rst_req <= 1'b0;
      end

      // RESUME: un-stall without releasing the lock.
      if (req_pending_r && req_cmd_r == CMD_RESUME && !refuse) begin
        cpu_freeze <= 1'b0;
      end

      // STEP: release the freeze for exactly the requested retirement count,
      // then reassert it (GRPR-DBG-021's CPU_HALTED analogue for STEP).
      if (req_pending_r && req_cmd_r == CMD_STEP && !refuse && !stepping_r) begin
        cpu_freeze <= 1'b0;
      end else if (stepping_r && cpu_trace_valid && step_count_r <= 8'h01) begin
        cpu_freeze <= 1'b1;
      end
    end
  end

  // --- Lock / release state machine -----------------------------------------

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      status_lock_active   <= 1'b0;
      status_lock_mode_act <= 1'b0;
      status_lock_pending  <= 1'b0;
      status_cpu_halted    <= 1'b0;
    end else begin
      // Accepting LOCK: latch the flavour, raise LOCK_PENDING for one cycle
      // (giving any address-phase CPU access one more cycle to complete
      // under mem_ready before dbg_own moves, per GRPR-DBG-009), then bring
      // the lock up on the following cycle.
      if (status_lock_pending) begin
        status_lock_pending <= 1'b0;
        status_lock_active  <= 1'b1;
        if (!status_lock_mode_act) begin
          status_cpu_halted <= 1'b1;
        end
      end else if (req_pending_r && req_cmd_r == CMD_LOCK && !refuse) begin
        status_lock_pending  <= 1'b1;
        status_lock_mode_act <= req_wdata_r[8] ? req_wdata_r[0] : ctrl_lock_mode;
      end

      if (req_pending_r && req_cmd_r == CMD_UNLOCK && !refuse &&
          bus_state_r == BUS_IDLE) begin
        status_lock_active <= 1'b0;
        status_cpu_halted  <= 1'b0;
      end

      if (req_pending_r && req_cmd_r == CMD_RESUME && !refuse) begin
        status_cpu_halted <= 1'b0;
      end
    end
  end

  // --- Step counting (trace-based, GRPR-DBG-025) ----------------------------

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      stepping_r       <= 1'b0;
      step_count_r     <= '0;
      status_step_done <= 1'b0;
    end else begin
      if (req_pending_r && req_cmd_r == CMD_STEP && !refuse && !stepping_r) begin
        stepping_r   <= 1'b1;
        step_count_r <= (req_wdata_r[7:0] == 8'h00) ? 8'h01 : req_wdata_r[7:0];
      end else if (stepping_r && cpu_trace_valid) begin
        if (step_count_r <= 8'h01) begin
          stepping_r       <= 1'b0;
          status_step_done <= 1'b1;
        end else begin
          step_count_r <= step_count_r - 8'h01;
        end
      end

      if (req_pending_r && req_cmd_r == CMD_REG_WRITE && !refuse &&
          req_addr_r[7:0] == REG_STATUS && req_wdata_r[7]) begin
        status_step_done <= 1'b0;
      end
    end
  end

  // --- Trace capture (GRPR-DBG-023 / -024) ----------------------------------
  //
  // Latch the most recent retired record. Valid clears on RESUME
  // (GRPR-DBG-024).
  //
  // DBGPC is NOT derived from this: picorv32's trace record carries either a
  // taken branch's target (TRACE_BRANCH) or a retiring instruction's
  // write-back value (the non-branch case) - never "the PC of the
  // instruction that just retired" in general. A CPU halted after a
  // non-branch instruction leaves no address in the record at all, so there
  // is no correct trace-based reconstruction of "the PC in effect when the
  // CPU halted" (GRPR-DBG-023). dbgpc_r is therefore left permanently at
  // its reset value and SEL_PC/REG_DBGPC are refused below - this needs
  // picorv32's own reg_pc ported to a real output, per GRPR-DBG-INFO-003.

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      dbgtrace_r       <= '0;
      dbgtrace_flags_r <= '0;
      dbgtrace_valid_r <= 1'b0;
    end else begin
      if (cpu_trace_valid) begin
        dbgtrace_r       <= cpu_trace_data[31:0];
        dbgtrace_flags_r <= cpu_trace_data[35:32];
        dbgtrace_valid_r <= 1'b1;
      end

      if (req_pending_r && req_cmd_r == CMD_RESUME && !refuse) begin
        dbgtrace_valid_r <= 1'b0;
      end
    end
  end

  // --- Bus error capture (GRPR-DBG-017) -------------------------------------

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      status_bus_err <= 1'b0;
      buserr_valid   <= 1'b0;
      buserr_cause   <= 1'b0;
      buserr_write   <= 1'b0;
      busaddr_r      <= '0;
      busdata_r      <= '0;
    end else begin
      if (bus_state_r == BUS_OWNED && dbg_ready) begin
        busaddr_r <= bus_addr_r;
        busdata_r <= bus_write_r ? bus_wdata_r : dbg_rdata;
        if (dbg_bus_error) begin
          status_bus_err <= 1'b1;
          buserr_valid   <= 1'b1;
          buserr_cause   <= 1'b0;   // AHB error response (no unmapped-address
                                    // detection distinct from cpu_ss's own
                                    // decode exists yet)
          buserr_write   <= bus_write_r;
        end
      end

      if (req_pending_r && req_cmd_r == CMD_REG_WRITE && !refuse &&
          req_addr_r[7:0] == REG_STATUS && req_wdata_r[6]) begin
        status_bus_err <= 1'b0;
      end
    end
  end

  // --- CTRL / DBGSEL writable state, REJECTED -------------------------------

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      ctrl_lock_en    <= 1'b0;   // GRPR-SOC-029: closed at reset, unconditionally
      ctrl_lock_mode  <= 1'b0;
      ctrl_dbg_en     <= 1'b0;
      dbgsel_r        <= '0;
      status_rejected <= 1'b0;
    end else begin
      if (req_pending_r) begin
        case (req_cmd_r)
          CMD_REG_WRITE: begin
            if (!refuse) begin
              if (req_addr_r[7:0] == REG_CTRL) begin
                ctrl_lock_en   <= req_wdata_r[0];
                ctrl_lock_mode <= req_wdata_r[1];
                ctrl_dbg_en    <= req_wdata_r[3];
              end else if (req_addr_r[7:0] == REG_DBGSEL) begin
                dbgsel_r <= req_wdata_r[4:0];
              end else if (req_addr_r[7:0] == REG_STATUS && req_wdata_r[5]) begin
                status_rejected <= 1'b0;
              end
            end
          end
          CMD_DBG_ENABLE: begin
            ctrl_lock_en <= 1'b1;
            ctrl_dbg_en  <= 1'b1;
          end
          default: begin end
        endcase

        if (refuse) begin
          status_rejected <= 1'b1;
        end
      end
    end
  end

  // --- Response data muxes ---------------------------------------------------

  logic [31:0] status_word;
  logic [31:0] reg_read_data;
  logic [31:0] state_read_data;

  assign status_word = {24'b0, status_step_done, status_bus_err,
                         status_rejected, 1'b0, status_cpu_halted,
                         status_lock_pending, status_lock_mode_act,
                         status_lock_active};

  always_comb begin
    case (req_addr_r[7:0])
      REG_CTRL:      reg_read_data = {28'b0, ctrl_dbg_en, 1'b0, ctrl_lock_mode, ctrl_lock_en};
      REG_STATUS:    reg_read_data = status_word;
      REG_BUSADDR:   reg_read_data = busaddr_r;
      REG_BUSDATA:   reg_read_data = busdata_r;
      REG_BUSERR:    reg_read_data = {29'b0, buserr_write, buserr_cause, buserr_valid};
      REG_DBGPC:     reg_read_data = 32'b0;   // no PC source yet - see the note
                                              // above the trace-capture block
      REG_DBGTRACE:  reg_read_data = dbgtrace_r;
      REG_DBGTRACEH: reg_read_data = {27'b0, dbgtrace_valid_r, dbgtrace_flags_r};
      REG_DBGREG:    reg_read_data = 32'b0;   // no GPR read port yet - see header
      REG_DBGSEL:    reg_read_data = {27'b0, dbgsel_r};
      default:       reg_read_data = 32'b0;
    endcase

    // SEL_PC is refused (sel_valid excludes it above), so it needs no entry
    // here; state_read_data's default covers it defensively.
    case (req_addr_r[7:0])
      SEL_TRACE_LOW:   state_read_data = dbgtrace_r;
      SEL_TRACE_FLAGS: state_read_data = {27'b0, dbgtrace_valid_r, dbgtrace_flags_r};
      default:         state_read_data = 32'b0;  // GPR range: no read port yet
    endcase
  end

  // --- Main request/response sequencing -------------------------------------

  always_ff @(posedge clk, negedge rst_n) begin
    if (~rst_n) begin
      req_pending_r <= 1'b0;
      req_cmd_r     <= '0;
      req_addr_r    <= '0;
      req_wdata_r   <= '0;
      req_size_r    <= '0;
      rsp_valid_r   <= 1'b0;
      rsp_rdata_r   <= '0;
      rsp_err_r     <= 1'b0;
    end else begin
      // Accept a new request.
      if (dbg_req_valid && dbg_req_ready) begin
        req_pending_r <= 1'b1;
        req_cmd_r     <= dbg_req_cmd;
        req_addr_r    <= dbg_req_addr;
        req_wdata_r   <= dbg_req_wdata;
        req_size_r    <= dbg_req_size;
      end

      // Consume a response.
      if (rsp_valid_r && dbg_rsp_ready) begin
        rsp_valid_r <= 1'b0;
      end

      // Produce the response. READ/WRITE wait for the bus FSM; everything
      // else completes the cycle after acceptance.
      if (req_pending_r && !rsp_valid_r) begin
        if (req_cmd_r == CMD_READ || req_cmd_r == CMD_WRITE) begin
          if (bus_state_r == BUS_OWNED && dbg_ready) begin
            req_pending_r <= 1'b0;
            rsp_valid_r   <= 1'b1;
            // dbg_rdata is the whole word the memory returned; a byte/
            // halfword-sized READ has to bring its target lane(s) back
            // down to rsp_rdata's low bits, the mirror image of how
            // bus_wdata_r above shifts a byte/halfword *up* into the lane
            // wstrb marks for a WRITE. Left unshifted, a READ at a
            // non-zero byte offset would return the whole word instead of
            // just the requested byte.
            case (req_size_r)
              2'd0:    // byte
                case (req_addr_r[1:0])
                  2'd0:    rsp_rdata_r <= {24'b0, dbg_rdata[7:0]};
                  2'd1:    rsp_rdata_r <= {24'b0, dbg_rdata[15:8]};
                  2'd2:    rsp_rdata_r <= {24'b0, dbg_rdata[23:16]};
                  default: rsp_rdata_r <= {24'b0, dbg_rdata[31:24]};
                endcase
              2'd1:    // halfword
                rsp_rdata_r <= req_addr_r[1] ? {16'b0, dbg_rdata[31:16]} : {16'b0, dbg_rdata[15:0]};
              default: // word
                rsp_rdata_r <= dbg_rdata;
            endcase
            rsp_err_r     <= dbg_bus_error;
          end
        end else begin
          req_pending_r <= 1'b0;
          rsp_valid_r   <= 1'b1;
          rsp_err_r     <= refuse;
          case (req_cmd_r)
            CMD_STATUS:     rsp_rdata_r <= status_word;   // GRPR-DBG-018: by command, not offset
            CMD_STATE_READ: rsp_rdata_r <= state_read_data;
            CMD_REG_READ:   rsp_rdata_r <= reg_read_data;
            default:        rsp_rdata_r <= 32'b0;
          endcase
        end
      end
    end
  end

endmodule
