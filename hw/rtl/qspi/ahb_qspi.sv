// AHB-Lite wrapper for the arbitrary-command quad QSPI engine

module ahb_qspi #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input  logic                  HCLK,
  input  logic                  HRESETn,

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

  output logic                  qspi_sck_o,
  output logic [1:0]            qspi_ce_n_o,
  input  logic [3:0]            qspi_sio_i,
  output logic [3:0]            qspi_sio_o,
  output logic [3:0]            qspi_sio_oe,

  output logic                  irq
);

  localparam logic [2:0] REG_CTRL   = 3'd0; // 0x00
  localparam logic [2:0] REG_STATUS = 3'd1; // 0x04
  localparam logic [2:0] REG_OPCODE = 3'd2; // 0x08
  localparam logic [2:0] REG_ADDR   = 3'd3; // 0x0C
  localparam logic [2:0] REG_DATA   = 3'd4; // 0x10

  // CTRL:
  //   [0]    START, action bit
  //   [1]    DIR, 0 = write and 1 = read
  //   [2]    TARGET
  //   [15:8] CLKDIV
  logic       ctrl_dir;
  logic       ctrl_target;
  logic [7:0] ctrl_clkdiv;

  logic [7:0]  opcode_reg;
  logic [23:0] address_reg;
  logic [7:0]  data_reg;

  logic core_start;
  logic core_busy;
  logic core_done;
  logic core_rx_valid;
  logic [7:0] core_read_data;

  logic status_done;
  logic status_rx_valid;

  logic       access;
  logic       access_valid;
  logic       write_pending;
  logic       read_pending;
  logic       access_error_r;
  logic [2:0] register_r;

  logic start_accepted;

  assign access =
      HSEL &&
      HREADYIN &&
      HTRANS[1];

  assign access_valid =
      (HSIZE == 3'b010) &&
      (HADDR[1:0] == 2'b00) &&
      (HADDR[11:5] == 7'h00) &&
      (HADDR[4:2] <= REG_DATA);

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      write_pending  <= 1'b0;
      read_pending   <= 1'b0;
      access_error_r <= 1'b0;
      register_r     <= 3'd0;
    end else begin
      write_pending  <= access && HWRITE;
      read_pending   <= access && !HWRITE;
      access_error_r <= access && !access_valid;
      register_r     <= HADDR[4:2];
    end
  end

  assign start_accepted =
      write_pending &&
      !access_error_r &&
      (register_r == REG_CTRL) &&
      HWDATA[0] &&
      !core_busy &&
      !core_start;

  always_ff @(posedge HCLK or negedge HRESETn) begin
    if (!HRESETn) begin
      ctrl_dir       <= 1'b0;
      ctrl_target    <= 1'b0;
      ctrl_clkdiv    <= 8'h00;

      opcode_reg     <= 8'h00;
      address_reg    <= 24'h000000;
      data_reg       <= 8'h00;

      core_start     <= 1'b0;
      status_done    <= 1'b0;
      status_rx_valid <= 1'b0;
    end else begin
      core_start <= 1'b0;

      if (
        write_pending &&
        !access_error_r
      ) begin
        unique case (register_r)
          REG_CTRL: begin
            ctrl_dir    <= HWDATA[1];
            ctrl_target <= HWDATA[2];
            ctrl_clkdiv <= HWDATA[15:8];

            if (start_accepted) begin
              core_start      <= 1'b1;
              status_done     <= 1'b0;
              status_rx_valid <= 1'b0;
            end
          end

          REG_OPCODE: begin
            opcode_reg <= HWDATA[7:0];
          end

          REG_ADDR: begin
            address_reg <= HWDATA[23:0];
          end

          REG_DATA: begin
            data_reg <= HWDATA[7:0];
          end

          default: begin
            // STATUS is read-only.
          end
        endcase
      end

      if (core_done) begin
        status_done <= 1'b1;
      end

      if (core_rx_valid) begin
        status_rx_valid <= 1'b1;
        data_reg        <= core_read_data;
      end
    end
  end

  always_comb begin
    HRDATA = '0;

    if (
      read_pending &&
      !access_error_r
    ) begin
      unique case (register_r)
        REG_CTRL: begin
          HRDATA[1]    = ctrl_dir;
          HRDATA[2]    = ctrl_target;
          HRDATA[15:8] = ctrl_clkdiv;
        end

        REG_STATUS: begin
          HRDATA[0] = core_busy;
          HRDATA[1] = status_done;
          HRDATA[2] = status_rx_valid;
        end

        REG_OPCODE: begin
          HRDATA[7:0] = opcode_reg;
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

  qspi u_qspi (
    .clk          (HCLK),
    .rst_n        (HRESETn),

    .start        (core_start),
    .dir          (ctrl_dir),
    .target       (ctrl_target),
    .clkdiv       (ctrl_clkdiv),

    .opcode       (opcode_reg),
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

  assign HREADYOUT = 1'b1;

  assign HRESP =
      (write_pending || read_pending) &&
      access_error_r;

  // Interrupts are outside the reduced scope.
  assign irq = 1'b0;

endmodule
