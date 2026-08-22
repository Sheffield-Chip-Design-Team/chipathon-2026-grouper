// AHB-Lite QSPI peripheral
//
// Register map:
//   0x00 CTRL
//   0x04 CMD
//   0x08 STATUS
//   0x0C ADDR
//   0x10 DATA
//
// CMD supplies an arbitrary opcode. DIR controls only the DATA phase direction

module ahb_qspi #(
  parameter int ADDR_WIDTH = 12,
  parameter int DATA_WIDTH = 32
) (
  input  logic                  HCLK,
  input  logic                  HRESETn,

  // AHB-Lite interface
  // Master -> Slave
  input  logic [ADDR_WIDTH-1:0] HADDR,
  input  logic [2:0]            HBURST,
  input  logic                  HMASTLOCK,
  input  logic [3:0]            HPROT,
  input  logic [2:0]            HSIZE,
  input  logic [1:0]            HTRANS,
  input  logic [DATA_WIDTH-1:0] HWDATA,
  input  logic                  HWRITE,
  
  // Slave -> Master
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,
 
  // Decoder Signals
  input  logic                  HREADYIN,
  input  logic                  HSEL,

  output logic                  qspi_sck_o,
  output logic [1:0]            qspi_ce_n_o,
  input  logic [3:0]            qspi_sio_i,
  output logic [3:0]            qspi_sio_o,
  output logic [3:0]            qspi_sio_oe,

  output logic                  irq
);

  localparam logic [2:0] REG_CTRL   = 3'd0; // 0x00
  localparam logic [2:0] REG_CMD    = 3'd1; // 0x04
  localparam logic [2:0] REG_STATUS = 3'd2; // 0x08
  localparam logic [2:0] REG_ADDR   = 3'd3; // 0x0C
  localparam logic [2:0] REG_DATA   = 3'd4; // 0x10

  // CTRL
  logic       ctrl_cpha;
  logic       ctrl_cpol;
  logic       ctrl_quad_mode;
  logic       ctrl_flash_write_en;
  logic       ctrl_ie_done;
  logic       ctrl_ie_err;
  logic [7:0] ctrl_clkdiv;

  // CMD
  //
  // [0]     START
  // [1]     DIR, DATA phase only: 0=write, 1=read
  // [2]     ADDR_EN
  // [3]     DATA_EN
  // [4]     TARGET, 0=PSRAM, 1=NOR
  // [7:5]   reserved
  // [15:8]  DUMMY
  // [23:16] OPCODE
  logic       cmd_dir;
  logic       cmd_addr_en;
  logic       cmd_data_en;
  logic       cmd_target;
  logic [7:0] cmd_dummy;
  logic [7:0] cmd_opcode;

  logic [23:0] address_reg;
  logic [7:0]  data_reg;

  // STATUS
  logic status_init_done;
  logic status_done;
  logic status_rx_valid;
  logic status_cfg_err;
  logic status_write_blocked;
  logic status_addr_err;

  // CPU-driven PSRAM initialisation tracking
  //
  // APS6404L starts in single-bit SPI mode. A successful bare PSRAM 0x35
  // command in single-bit mode marks the SPI -> QPI initialisation complete
  typedef enum logic {
    INIT_WAIT_QPI_CMD,
    INIT_COMPLETE
  } init_state_t;

  init_state_t init_state;
  logic        init_cmd_in_flight;

  // AHB pipeline
  logic       access;
  logic       transfer_valid;
  logic       write_pending;
  logic       read_pending;
  logic       access_error_r;
  logic [2:0] register_r;

  logic [3:0] byte_select;
  logic [3:0] byte_select_r;

  // QSPI core interface
  logic       core_start;
  logic       core_busy;
  logic       core_done;
  logic       core_rx_valid;
  logic [7:0] core_read_data;

  // START checks
  logic start_requested;
  logic start_dir;
  logic start_addr_en;
  logic start_data_en;
  logic start_target;

  logic start_blocked_flash;
  logic start_bad_address;
  logic start_bad_mode;
  logic start_busy_error;
  logic start_accepted;

  logic ctrl_write_while_busy;

  logic cfg_error_event;
  logic write_blocked_event;
  logic addr_error_event;

  // Two-cycle AHB error response
  logic error_first_cycle;
  logic error_second_cycle;

  assign access = HSEL && HREADYIN && HTRANS[1];

  // AHB access size / byte lanes
  always_comb begin
    byte_select    = 4'b0000;
    transfer_valid = 1'b0;

    unique case (HSIZE)

      3'b000: begin
        // Byte access
        byte_select =
            4'b0001 << HADDR[1:0];

        transfer_valid = 1'b1;
      end

      3'b001: begin
        // Halfword access
        if (!HADDR[0]) begin
          byte_select =
              HADDR[1]
              ? 4'b1100
              : 4'b0011;

          transfer_valid = 1'b1;
        end
      end

      3'b010: begin
        // Word access
        if (HADDR[1:0] == 2'b00) begin
          byte_select    = 4'b1111;
          transfer_valid = 1'b1;
        end
      end

      default: begin
        byte_select    = 4'b0000;
        transfer_valid = 1'b0;
      end

    endcase

    // Five implemented registers inside the local 4 KiB peripheral window
    if (
      (HADDR[11:5] != 7'h00) ||
      (HADDR[4:2] > REG_DATA)
    ) begin
      transfer_valid = 1'b0;
    end
  end

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      write_pending  <= 1'b0;
      read_pending   <= 1'b0;
      access_error_r <= 1'b0;
      register_r     <= 3'd0;
      byte_select_r  <= 4'b0000;
    end else begin
      write_pending  <= access && HWRITE;
      read_pending   <= access && !HWRITE;
      access_error_r <= access && !transfer_valid;
      register_r     <= HADDR[4:2];
      byte_select_r  <= byte_select;
    end
  end

  // Effective CMD byte-0 fields for a write that may update CMD and START
  // in the same AHB transfer
  assign start_dir =
      byte_select_r[0]
      ? HWDATA[1]
      : cmd_dir;

  assign start_addr_en =
      byte_select_r[0]
      ? HWDATA[2]
      : cmd_addr_en;

  assign start_data_en =
      byte_select_r[0]
      ? HWDATA[3]
      : cmd_data_en;

  assign start_target =
      byte_select_r[0]
      ? HWDATA[4]
      : cmd_target;

  assign start_requested =
      write_pending &&
      !access_error_r &&
      (register_r == REG_CMD) &&
      byte_select_r[0] &&
      HWDATA[0];

  assign start_busy_error =
      start_requested &&
      core_busy;

  // Only SPI modes 0 and 3 are supported:
  //   CPOL=0 CPHA=0
  //   CPOL=1 CPHA=1
  assign start_bad_mode =
      start_requested &&
      !core_busy &&
      (ctrl_cpha != ctrl_cpol);

  // APS6404L uses a 23-bit address
  assign start_bad_address =
      start_requested &&
      !core_busy &&
      start_addr_en &&
      !start_target &&
      address_reg[23];

  // NOR write-directed transactions require FLASH_WRITE_EN
  //
  // DIR is only the DATA direction. It does not select an opcode
  assign start_blocked_flash =
      start_requested &&
      !core_busy &&
      start_target &&
      start_data_en &&
      !start_dir &&
      !ctrl_flash_write_en;

  assign ctrl_write_while_busy =
      write_pending &&
      !access_error_r &&
      (register_r == REG_CTRL) &&
      core_busy;

  assign cfg_error_event =
      ctrl_write_while_busy ||
      start_busy_error ||
      start_bad_mode;

  assign write_blocked_event =
      start_blocked_flash;

  assign addr_error_event =
      start_bad_address;

  assign start_accepted =
      start_requested &&
      !core_busy &&
      !start_bad_mode &&
      !start_bad_address &&
      !start_blocked_flash;

  // --- AHB Write Logic -----------------------------------------

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      ctrl_cpha           <= 1'b0;
      ctrl_cpol           <= 1'b0;
      ctrl_quad_mode      <= 1'b0;
      ctrl_flash_write_en <= 1'b0;
      ctrl_ie_done        <= 1'b0;
      ctrl_ie_err         <= 1'b0;
      ctrl_clkdiv         <= 8'h00;

      cmd_dir             <= 1'b0;
      cmd_addr_en         <= 1'b0;
      cmd_data_en         <= 1'b0;
      cmd_target          <= 1'b0;
      cmd_dummy           <= 8'h00;
      cmd_opcode          <= 8'h00;

      address_reg         <= 24'h000000;
      data_reg            <= 8'h00;

      status_init_done     <= 1'b0;
      status_done          <= 1'b0;
      status_rx_valid      <= 1'b0;
      status_cfg_err       <= 1'b0;
      status_write_blocked <= 1'b0;
      status_addr_err      <= 1'b0;

      init_state         <= INIT_WAIT_QPI_CMD;
      init_cmd_in_flight <= 1'b0;

      core_start <= 1'b0;
    end else begin
      core_start <= 1'b0;

      // STATUS W1C fields
      //
      // Hardware events later in this block have priority over software
      // clears if both happen in the same cycle
      if (
        write_pending &&
        !access_error_r &&
        (register_r == REG_STATUS) &&
        byte_select_r[0]
      ) begin
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

      if (
        write_pending &&
        !access_error_r
      ) begin
        unique case (register_r)

          REG_CTRL: begin
            // CTRL writes while BUSY are ignored
            if (!core_busy) begin
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
            // START while BUSY rejects the entire CMD write
            //
            // Descriptor-only writes while BUSY remain permitted because the
            // core latches the active transaction descriptor at START
            if (!start_busy_error) begin
              if (byte_select_r[0]) begin
                cmd_dir     <= HWDATA[1];
                cmd_addr_en <= HWDATA[2];
                cmd_data_en <= HWDATA[3];
                cmd_target  <= HWDATA[4];
              end

              if (byte_select_r[1]) begin
                cmd_dummy <= HWDATA[15:8];
              end

              if (byte_select_r[2]) begin
                cmd_opcode <= HWDATA[23:16];
              end
            end

            if (start_accepted) begin
              core_start <= 1'b1;

              // CPU-driven APS6404L single-bit SPI -> QPI initialisation
              if (
                (init_state == INIT_WAIT_QPI_CMD) &&
                !ctrl_quad_mode &&
                !start_target &&
                !start_addr_en &&
                !start_data_en &&
                (
                  byte_select_r[2]
                  ? (HWDATA[23:16] == 8'h35)
                  : (cmd_opcode == 8'h35)
                )
              ) begin
                init_cmd_in_flight <= 1'b1;
              end
            end
          end

          REG_ADDR: begin
            if (byte_select_r[0]) begin
              address_reg[7:0] <= HWDATA[7:0];
            end

            if (byte_select_r[1]) begin
              address_reg[15:8] <= HWDATA[15:8];
            end

            if (byte_select_r[2]) begin
              address_reg[23:16] <= HWDATA[23:16];
            end
          end

          REG_DATA: begin
            if (byte_select_r[0]) begin
              data_reg <= HWDATA[7:0];
            end
          end

          default: begin
            // STATUS W1C handled above
          end

        endcase
      end

      if (core_done) begin
        status_done <= 1'b1;

        if (init_cmd_in_flight) begin
          init_cmd_in_flight <= 1'b0;
          init_state         <= INIT_COMPLETE;
          status_init_done   <= 1'b1;
        end
      end

      if (core_rx_valid) begin
        status_rx_valid <= 1'b1;

        // Deliberately retain the shared DATA-register behaviour identified
        // in PR #23: completed RX replaces the previous transmit byte
        data_reg <= core_read_data;
      end

      if (cfg_error_event) begin
        status_cfg_err <= 1'b1;
      end

      if (write_blocked_event) begin
        status_write_blocked <= 1'b1;
      end

      if (addr_error_event) begin
        status_addr_err <= 1'b1;
      end
    end
  end

  // --- AHB Read Logic -----------------------------------------

  always_comb begin
    HRDATA = '0;

    if (
      read_pending &&
      !access_error_r
    ) begin
      unique case (register_r)

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
          HRDATA[0]     = 1'b0;
          HRDATA[1]     = cmd_dir;
          HRDATA[2]     = cmd_addr_en;
          HRDATA[3]     = cmd_data_en;
          HRDATA[4]     = cmd_target;
          HRDATA[15:8]  = cmd_dummy;
          HRDATA[23:16] = cmd_opcode;
        end

        REG_STATUS: begin
          HRDATA[0] = core_busy;
          HRDATA[1] = status_init_done;
          HRDATA[2] = status_done;
          HRDATA[3] = status_rx_valid;
          HRDATA[4] = status_cfg_err;
          HRDATA[5] = status_write_blocked;
          HRDATA[6] = status_addr_err;
        end

        REG_ADDR: begin
          HRDATA[23:0] = address_reg;
        end

        REG_DATA: begin
          HRDATA[7:0] = data_reg;
        end

        default: begin
          HRDATA = '0;
        end

      endcase
    end
  end

  // --- QSPI Serial engine -----------------------------------------

  qspi u_qspi (
    .clk          (HCLK),
    .rst_n        (HRESETn),

    .start        (core_start),
    .dir          (cmd_dir),
    .addr_en      (cmd_addr_en),
    .data_en      (cmd_data_en),
    .target       (cmd_target),

    .quad_mode    (ctrl_quad_mode),
    .cpol         (ctrl_cpol),
    .cpha         (ctrl_cpha),
    .clkdiv       (ctrl_clkdiv),

    .dummy        (cmd_dummy),
    .opcode       (cmd_opcode),
    .address      (address_reg),
    .write_data   (data_reg),

    .busy         (core_busy),
    .done         (core_done),
    .rx_valid     (core_rx_valid),
    .read_data    (core_read_data),

    .qspi_sck_o   (qspi_sck_o),
    .qspi_ce_n_o  (qspi_ce_n_o),
    .qspi_sio_i   (qspi_sio_i),
    .qspi_sio_o   (qspi_sio_o),
    .qspi_sio_oe  (qspi_sio_oe)
  );

  //  ---- AHB-Lite ERROR response --------------------------------------------
  // Cycle 1:
  //   HRESP     = 1 , HREADYOUT = 0
  // Cycle 2:
  //   HRESP     = 1,  HREADYOUT = 1

  assign error_first_cycle = !error_second_cycle // FIXME - can this be simplifies?
  && (
     ((write_pending || read_pending) && access_error_r) 
      || start_blocked_flash );

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      error_second_cycle <= 1'b0;
    end else if (error_second_cycle) begin
      error_second_cycle <= 1'b0;
    end else if (error_first_cycle) begin
      error_second_cycle <= 1'b1;
    end
  end

  assign HRESP = error_first_cycle || error_second_cycle;
  assign HREADYOUT = !error_first_cycle;
  
  // ---- Combined interrupt ---------------------------------------------------
  assign irq = ((status_done && ctrl_ie_done) || 
  (( status_cfg_err || status_write_blocked   || status_addr_err)
                                              && ctrl_ie_err ));

endmodule