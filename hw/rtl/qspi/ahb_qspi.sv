// AHB-Lite-controlled QSPI transaction peripheral

module ahb_qspi #(
  parameter int         ADDR_WIDTH   = 32,
  parameter int         DATA_WIDTH   = 32,
  parameter logic [7:0] CLKDIV_RESET = 8'h00
) (
  input  logic                  HCLK,
  input  logic                  HRESETn,

  // --------------------------------------------------------------------------
  // AHB-Lite subordinate interface
  // GRPR-QSPI-001
  // --------------------------------------------------------------------------

  input  logic [ADDR_WIDTH-1:0] HADDR,
  input  logic [2:0]            HBURST,
  input  logic                  HMASTLOCK,
  input  logic [3:0]            HPROT,
  input  logic [2:0]            HSIZE,
  input  logic [1:0]            HTRANS,
  input  logic [DATA_WIDTH-1:0] HWDATA,
  input  logic                  HWRITE,

  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  input  logic                  HREADYIN,
  input  logic                  HSEL,

  // --------------------------------------------------------------------------
  // External QSPI interface
  //
  // qspi_ce_n_o[0] = PSRAM chip enable
  // qspi_ce_n_o[1] = NOR-flash chip enable
  //
  // Final physical routing remains subject to GPIO-mux integration review.
  // --------------------------------------------------------------------------

  output logic                  qspi_sck_o,
  output logic [1:0]            qspi_ce_n_o,
  input  logic [3:0]            qspi_sio_i,
  output logic [3:0]            qspi_sio_o,
  output logic [3:0]            qspi_sio_oe,

  // Combined interrupt
  output logic                  irq
);

  import ahb3lite_pkg::*;

  // --------------------------------------------------------------------------
  // Fixed architectural widths
  // --------------------------------------------------------------------------

  localparam int CLKDIV_WIDTH    = 8;
  localparam int QSPI_ADDR_WIDTH = 24;
  localparam int QSPI_DATA_WIDTH = 8;

  // --------------------------------------------------------------------------
  // Register word addresses
  // --------------------------------------------------------------------------

  localparam logic [2:0] REG_CTRL   = 3'd0; // 0x00
  localparam logic [2:0] REG_CMD    = 3'd1; // 0x04
  localparam logic [2:0] REG_STATUS = 3'd2; // 0x08
  localparam logic [2:0] REG_ADDR   = 3'd3; // 0x0C
  localparam logic [2:0] REG_DATA   = 3'd4; // 0x10

  // --------------------------------------------------------------------------
  // CTRL register fields
  // GRPR-QSPI-009, GRPR-QSPI-010 and GRPR-QSPI-012
  // --------------------------------------------------------------------------

  logic                       ctrl_cpha;
  logic                       ctrl_cpol;
  logic                       ctrl_quad_mode;
  logic                       ctrl_flash_write_en;
  logic                       ctrl_ie_done;
  logic                       ctrl_ie_err;
  logic [CLKDIV_WIDTH-1:0]    ctrl_clkdiv;

  // --------------------------------------------------------------------------
  // CMD register fields
  // GRPR-QSPI-008, GRPR-QSPI-011 and GRPR-QSPI-013
  //
  // START is not stored. A legal write of START=1 produces a one-cycle pulse.
  // --------------------------------------------------------------------------

  logic                       cmd_dir;
  logic                       cmd_addr_en;
  logic                       cmd_data_en;
  logic                       cmd_target;
  logic                       cmd_fast_txn_en;
  logic [7:0]                 cmd_dummy;

  // --------------------------------------------------------------------------
  // ADDR and DATA registers
  // --------------------------------------------------------------------------

  logic [QSPI_ADDR_WIDTH-1:0] qspi_addr;
  logic [QSPI_DATA_WIDTH-1:0] qspi_data;

  // --------------------------------------------------------------------------
  // Live status supplied by the future transaction engine
  // --------------------------------------------------------------------------

  logic core_busy;
  logic core_init_done;

  // --------------------------------------------------------------------------
  // One-cycle event pulses supplied by the future transaction engine
  // --------------------------------------------------------------------------

  logic core_done;
  logic core_rx_valid;
  logic core_cfg_err;
  logic core_write_blocked;
  logic core_addr_err;

  // --------------------------------------------------------------------------
  // Sticky software-visible STATUS fields
  // GRPR-QSPI-015
  // --------------------------------------------------------------------------

  logic status_done;
  logic status_rx_valid;
  logic status_cfg_err;
  logic status_write_blocked;
  logic status_addr_err;

  // --------------------------------------------------------------------------
  // Wrapper-to-core transaction request
  // --------------------------------------------------------------------------

  logic                        core_start;

  logic                        core_dir;
  logic                        core_addr_en;
  logic                        core_data_en;
  logic                        core_target;
  logic                        core_fast_txn_en;
  logic [7:0]                  core_dummy;

  logic                        core_cpha;
  logic                        core_cpol;
  logic                        core_quad_mode;
  logic [CLKDIV_WIDTH-1:0]     core_clkdiv;

  logic [QSPI_ADDR_WIDTH-1:0]  core_address;
  logic [QSPI_DATA_WIDTH-1:0]  core_write_data;
  logic [QSPI_DATA_WIDTH-1:0]  core_read_data;

  // --------------------------------------------------------------------------
  // AHB address-phase and data-phase control
  // --------------------------------------------------------------------------

  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;

  logic [2:0]                 word_address;
  logic [2:0]                 word_address_r;

  logic [3:0]                 byte_select;
  logic [3:0]                 byte_select_r;

  logic                       transfer_size_valid;
  logic                       register_offset_valid;
  logic                       address_phase_valid;
  logic                       access_error_r;

  // --------------------------------------------------------------------------
  // Register-write and transaction-validation control
  // --------------------------------------------------------------------------

  logic transaction_locked;
  logic write_to_frozen_register;

  logic cmd_start_requested;
  logic start_candidate;
  logic start_write_blocked_event;
  logic start_addr_err_event;
  logic start_accepted;

  logic effective_cmd_dir;
  logic effective_cmd_addr_en;
  logic effective_cmd_target;

  logic wrapper_cfg_err_event;
  logic status_w1c;

  // --------------------------------------------------------------------------
  // AHB address-phase access detection
  //
  // HTRANS[1] accepts NONSEQ and SEQ while rejecting IDLE and BUSY.
  // --------------------------------------------------------------------------

  assign access =
      HREADYIN &&
      HSEL &&
      HTRANS[1];

  assign read_enable =
      access &&
      !HWRITE;

  assign word_address =
      access
          ? HADDR[4:2]
          : '0;

  // --------------------------------------------------------------------------
  // Transfer-size and alignment validation
  // --------------------------------------------------------------------------

  always_comb begin
    transfer_size_valid = 1'b0;

    unique case (HSIZE)
      3'b000: begin
        // Byte transfer: every byte address is naturally aligned.
        transfer_size_valid = 1'b1;
      end

      3'b001: begin
        // Halfword transfer: address bit 0 must be zero.
        transfer_size_valid = !HADDR[0];
      end

      3'b010: begin
        // Word transfer: address bits 1:0 must both be zero.
        transfer_size_valid = (HADDR[1:0] == 2'b00);
      end

      default: begin
        // Transfers wider than the 32-bit register bus are unsupported.
        transfer_size_valid = 1'b0;
      end
    endcase
  end

  // The peripheral owns a 4 KiB region, but only offsets 0x00-0x10 are
  // implemented. Checking HADDR[11:5] prevents higher addresses in the same
  // 4 KiB region from aliasing onto the five real registers.
  assign register_offset_valid =
      (HADDR[11:5] == 7'b0000000) &&
      (HADDR[4:2] <= REG_DATA);

  assign address_phase_valid =
      transfer_size_valid &&
      register_offset_valid;

  assign byte_select =
      (access && transfer_size_valid)
          ? generate_byte_select_32(HSIZE, HADDR[1:0])
          : 4'b0000;

  // --------------------------------------------------------------------------
  // Delay address-phase information into the AHB data phase
  // --------------------------------------------------------------------------

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      write_enable   <= 1'b0;
      read_enable_r  <= 1'b0;
      word_address_r <= '0;
      byte_select_r  <= '0;
      access_error_r <= 1'b0;
    end else begin
      write_enable   <= access && HWRITE;
      read_enable_r  <= read_enable;
      word_address_r <= word_address;
      byte_select_r  <= byte_select;
      access_error_r <= access && !address_phase_valid;
    end
  end

  // --------------------------------------------------------------------------
  // Transaction locking
  //
  // core_start is included because the future core will not assert core_busy
  // until it samples the start pulse. This closes the one-cycle gap in which a
  // second command could otherwise be accepted.
  // --------------------------------------------------------------------------

  assign transaction_locked =
      core_busy ||
      core_start;

  assign write_to_frozen_register =
      write_enable &&
      !access_error_r &&
      transaction_locked &&
      (
        (word_address_r == REG_CTRL) ||
        (word_address_r == REG_CMD)  ||
        (word_address_r == REG_ADDR) ||
        (word_address_r == REG_DATA)
      );

  assign wrapper_cfg_err_event =
      write_to_frozen_register;

  // --------------------------------------------------------------------------
  // Effective CMD descriptor for same-write START validation
  //
  // A CMD write may change DIR, ADDR_EN or TARGET and assert START in the same
  // AHB store. Validation must therefore use the incoming values rather than
  // the previous register contents.
  // --------------------------------------------------------------------------

  assign effective_cmd_dir =
      byte_select_r[0]
          ? HWDATA[1]
          : cmd_dir;

  assign effective_cmd_addr_en =
      byte_select_r[0]
          ? HWDATA[2]
          : cmd_addr_en;

  assign effective_cmd_target =
      byte_select_r[0]
          ? HWDATA[4]
          : cmd_target;

  assign cmd_start_requested =
      write_enable &&
      !access_error_r &&
      (word_address_r == REG_CMD) &&
      byte_select_r[0] &&
      HWDATA[0];

  assign start_candidate =
      cmd_start_requested &&
      !transaction_locked;

  // A NOR-flash write is blocked unless firmware has explicitly enabled the
  // flash-write path in CTRL.
  assign start_write_blocked_event =
      start_candidate &&
      effective_cmd_target &&
      !effective_cmd_dir &&
      !ctrl_flash_write_en;

  // PSRAM is 8 MB: valid 24-bit payloads have ADDR[23] = 0.
  // NOR flash is 4 MB: valid payloads have ADDR[23:22] = 2'b00.
  assign start_addr_err_event =
      start_candidate &&
      effective_cmd_addr_en &&
      (
        (!effective_cmd_target && qspi_addr[23]) ||
        ( effective_cmd_target && (|qspi_addr[23:22]))
      );

  assign start_accepted =
      start_candidate &&
      !start_write_blocked_event &&
      !start_addr_err_event;

  // --------------------------------------------------------------------------
  // Software-visible register storage
  // --------------------------------------------------------------------------

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      // CTRL
      ctrl_cpha           <= 1'b0;
      ctrl_cpol           <= 1'b0;
      ctrl_quad_mode      <= 1'b0;
      ctrl_flash_write_en <= 1'b0;
      ctrl_ie_done        <= 1'b0;
      ctrl_ie_err         <= 1'b0;
      ctrl_clkdiv         <= CLKDIV_RESET;

      // CMD
      cmd_dir             <= 1'b0;
      cmd_addr_en         <= 1'b0;
      cmd_data_en         <= 1'b0;
      cmd_target          <= 1'b0;
      cmd_fast_txn_en     <= 1'b0;
      cmd_dummy           <= 8'h00;

      // ADDR and DATA
      qspi_addr           <= '0;
      qspi_data           <= '0;

      // START is a pulse rather than a stored register field.
      core_start          <= 1'b0;
    end else begin
      // Default pulse behaviour. An accepted CMD write overrides this below.
      core_start <= 1'b0;

      if (write_enable && !access_error_r) begin
        unique case (word_address_r)
          REG_CTRL: begin
            if (!transaction_locked) begin
              if (byte_select_r[0]) begin
                ctrl_cpha           <= HWDATA[0];
                ctrl_cpol           <= HWDATA[1];
                ctrl_quad_mode      <= HWDATA[2];
                ctrl_flash_write_en <= HWDATA[3];
                ctrl_ie_done        <= HWDATA[4];
                ctrl_ie_err         <= HWDATA[5];
              end

              if (byte_select_r[1]) begin
                ctrl_clkdiv <= HWDATA[15:8];
              end
            end
          end

          REG_CMD: begin
            if (!transaction_locked) begin
              if (byte_select_r[0]) begin
                cmd_dir         <= HWDATA[1];
                cmd_addr_en     <= HWDATA[2];
                cmd_data_en     <= HWDATA[3];
                cmd_target      <= HWDATA[4];
                cmd_fast_txn_en <= HWDATA[5];
              end

              if (byte_select_r[1]) begin
                cmd_dummy <= HWDATA[15:8];
              end

              if (start_accepted) begin
                core_start <= 1'b1;
              end
            end
          end

          REG_STATUS: begin
            // STATUS W1C behaviour is implemented in the status block below.
          end

          REG_ADDR: begin
            if (!transaction_locked) begin
              if (byte_select_r[0]) begin
                qspi_addr[7:0] <= HWDATA[7:0];
              end

              if (byte_select_r[1]) begin
                qspi_addr[15:8] <= HWDATA[15:8];
              end

              if (byte_select_r[2]) begin
                qspi_addr[23:16] <= HWDATA[23:16];
              end
            end
          end

          REG_DATA: begin
            if (!transaction_locked && byte_select_r[0]) begin
              qspi_data <= HWDATA[7:0];
            end
          end

          default: begin
            // Invalid offsets are suppressed by access_error_r.
          end
        endcase
      end

      // A received byte has priority over a simultaneous software DATA write.
      if (core_rx_valid) begin
        qspi_data <= core_read_data;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sticky STATUS fields and write-one-to-clear behaviour
  //
  // Event setting is placed after software clearing, giving new hardware
  // events priority if a clear and a new event occur in the same cycle.
  // --------------------------------------------------------------------------

  assign status_w1c =
      write_enable &&
      !access_error_r &&
      (word_address_r == REG_STATUS) &&
      byte_select_r[0];

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      status_done          <= 1'b0;
      status_rx_valid      <= 1'b0;
      status_cfg_err       <= 1'b0;
      status_write_blocked <= 1'b0;
      status_addr_err      <= 1'b0;
    end else begin
      if (status_w1c) begin
        if (HWDATA[2]) begin
          status_done <= 1'b0;
        end

        if (HWDATA[3]) begin
          status_rx_valid <= 1'b0;
        end

        if (HWDATA[4]) begin
          status_cfg_err <= 1'b0;
        end

        if (HWDATA[5]) begin
          status_write_blocked <= 1'b0;
        end

        if (HWDATA[6]) begin
          status_addr_err <= 1'b0;
        end
      end

      if (core_done) begin
        status_done <= 1'b1;
      end

      if (core_rx_valid) begin
        status_rx_valid <= 1'b1;
      end

      if (core_cfg_err || wrapper_cfg_err_event) begin
        status_cfg_err <= 1'b1;
      end

      if (core_write_blocked || start_write_blocked_event) begin
        status_write_blocked <= 1'b1;
      end

      if (core_addr_err || start_addr_err_event) begin
        status_addr_err <= 1'b1;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Register readback
  // --------------------------------------------------------------------------

  always_comb begin
    HRDATA = '0;

    if (read_enable_r && !access_error_r) begin
      unique case (word_address_r)
        REG_CTRL: begin
          HRDATA[0]    = ctrl_cpha;
          HRDATA[1]    = ctrl_cpol;
          HRDATA[2]    = ctrl_quad_mode;
          HRDATA[3]    = ctrl_flash_write_en;
          HRDATA[4]    = ctrl_ie_done;
          HRDATA[5]    = ctrl_ie_err;
          HRDATA[15:8] = ctrl_clkdiv;
        end

        REG_CMD: begin
          // START always reads as zero.
          HRDATA[1]    = cmd_dir;
          HRDATA[2]    = cmd_addr_en;
          HRDATA[3]    = cmd_data_en;
          HRDATA[4]    = cmd_target;
          HRDATA[5]    = cmd_fast_txn_en;
          HRDATA[15:8] = cmd_dummy;
        end

        REG_STATUS: begin
          HRDATA[0] = core_busy;
          HRDATA[1] = core_init_done;
          HRDATA[2] = status_done;
          HRDATA[3] = status_rx_valid;
          HRDATA[4] = status_cfg_err;
          HRDATA[5] = status_write_blocked;
          HRDATA[6] = status_addr_err;
        end

        REG_ADDR: begin
          HRDATA[23:0] = qspi_addr;
        end

        REG_DATA: begin
          HRDATA[7:0] = qspi_data;
        end

        default: begin
          HRDATA = '0;
        end
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // Register fields presented directly to the future transaction engine
  //
  // These are wires rather than a duplicate transaction-register bank.
  // --------------------------------------------------------------------------

  assign core_dir         = cmd_dir;
  assign core_addr_en     = cmd_addr_en;
  assign core_data_en     = cmd_data_en;
  assign core_target      = cmd_target;
  assign core_fast_txn_en = cmd_fast_txn_en;
  assign core_dummy       = cmd_dummy;

  assign core_cpha        = ctrl_cpha;
  assign core_cpol        = ctrl_cpol;
  assign core_quad_mode   = ctrl_quad_mode;
  assign core_clkdiv      = ctrl_clkdiv;

  assign core_address     = qspi_addr;
  assign core_write_data  = qspi_data;

  // --------------------------------------------------------------------------
  // Temporary transaction-engine model
  //
  // The existing qspi.sv remains the copied legacy scaffold, so it is not
  // instantiated during the register-shell milestone.
  // --------------------------------------------------------------------------

  assign core_busy          = 1'b0;
  assign core_init_done     = 1'b0;

  assign core_done          = 1'b0;
  assign core_rx_valid      = 1'b0;
  assign core_cfg_err       = 1'b0;
  assign core_write_blocked = 1'b0;
  assign core_addr_err      = 1'b0;

  assign core_read_data     = 8'h00;

  // --------------------------------------------------------------------------
  // Combined interrupt generation
  // --------------------------------------------------------------------------

  assign irq =
      (status_done && ctrl_ie_done) ||
      (
        (
          status_cfg_err       ||
          status_write_blocked ||
          status_addr_err
        ) &&
        ctrl_ie_err
      );

  // --------------------------------------------------------------------------
  // Safe inactive external QSPI outputs
  // --------------------------------------------------------------------------

  assign qspi_sck_o  = ctrl_cpol;
  assign qspi_ce_n_o = 2'b11;
  assign qspi_sio_o  = 4'b0000;
  assign qspi_sio_oe = 4'b0000;

  // --------------------------------------------------------------------------
  // AHB response
  //
  // Operational rejections such as protected flash writes are reported through
  // STATUS. HRESP is reserved here for malformed transfers or unimplemented
  // register offsets.
  // --------------------------------------------------------------------------

  assign HREADYOUT = 1'b1;

  assign HRESP =
      (write_enable || read_enable_r) &&
      access_error_r;

endmodule