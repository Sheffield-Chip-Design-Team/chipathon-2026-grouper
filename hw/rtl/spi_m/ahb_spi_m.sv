// AHB spi master

module ahb_spi_m #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // GRPR-SPIM-001
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

  output logic                  SPI_MOSI,
  output logic                  SPI_SCK,
  output logic                  SPI_CS_N,
  input  logic                  SPI_MISO,

  output logic                  irq
  
);

import ahb3lite_pkg::*;

localparam int CLK_DIV_BITS = 8;
localparam int SPI_DATA_W   = 8;

localparam logic [2:0] ADDR_CTRL   = 3'd0;
localparam logic [2:0] ADDR_CMD    = 3'd1;
localparam logic [2:0] ADDR_STATUS = 3'd2;
localparam logic [2:0] ADDR_INT    = 3'd3;
localparam logic [2:0] ADDR_ADDR   = 3'd4;
localparam logic [2:0] ADDR_DATA   = 3'd5;

// Control registers -- GRPR-SPIM-009, GRPR-SPIM-012
logic       ctrl_cpha;
logic       ctrl_cpol;
logic [7:0] ctrl_clk_div;
logic       ctrl_ie_done;
logic       ctrl_ie_err;

// CMD register
logic        cmd_start;
logic [7:0]  cmd_opcode;
logic        cmd_en;
logic        cmd_addr_en;
logic [1:0]  cmd_addr_bytes;
logic        cmd_data_en;
logic        cmd_dir;
logic [4:0]  cmd_dummy;
logic [7:0]  cmd_len;

// Status
logic status_busy;
logic status_tx_empty;
logic status_tx_full;
logic status_rx_empty;
logic status_rx_full;
logic [2:0] status_tx_level;
logic [2:0] status_rx_level;

// INT register
logic int_done;
logic int_overrun;
logic int_underrun;
logic int_cfg_err;

// SPI registers
logic [31:0] spi_addr;


// RX last value reg
logic [7:0] rx_last_data;

// AHB pipeline
logic                       access;
logic                       read_enable;
logic                       read_enable_r;
logic                       write_enable;
logic [2:0]                 word_address;
logic [2:0]                 word_address_r;
logic [(DATA_WIDTH/8)-1:0]  byte_select;
logic [(DATA_WIDTH/8)-1:0]  byte_select_r;
logic [DATA_WIDTH-1:0]      hwdata_r;      // registered HWDATA
logic                       invalid_access;

// Internal
logic spi_busy;
logic spi_done;
logic [7:0] rx_data;
logic rx_full;
logic rx_empty;
logic tx_full;
logic tx_empty;

// error detection
logic cfg_error_access;

assign cfg_error_access =
    write_enable &&
    (word_address_r == ADDR_CTRL) &&
    byte_select_r[0] &&
    (hwdata_r[0] != hwdata_r[1]);

//------------------------------------------------------
// SPI core instantiation
//------------------------------------------------------

spi_m_core #(
    .DATA_WIDTH (8),
    .FIFO_DEPTH (4)
) u_spi_m_core (
    .clk            (HCLK),
    .rst_n          (HRESETn),
    .enable         (1'b1),
    .start          (cmd_start),
    .cpol           (ctrl_cpol),
    .cpha           (ctrl_cpha),
    .clk_div        (ctrl_clk_div),
    .opcode         (cmd_opcode),
    .cmd_en         (cmd_en),
    .addr_en        (cmd_addr_en),
    .addr_bytes     (cmd_addr_bytes),
    .addr           (spi_addr),
    .data_en        (cmd_data_en),
    .dir            (cmd_dir),
    .dummy_cycles   (cmd_dummy),
    .data_len       (cmd_len),
    .flush_tx_fifo  (1'b0),
    .tx_write       (write_enable && (word_address_r == ADDR_DATA) && !tx_full),
    .tx_data        (hwdata_r[7:0]),
    .tx_full        (tx_full),
    .tx_empty       (tx_empty),
    
    .flush_rx_fifo  (1'b0),
    .rx_read        (read_enable_r && (word_address_r == ADDR_DATA) && !rx_empty),
    .rx_data        (rx_data),
    .rx_full        (rx_full),
    .rx_empty       (rx_empty),

    .busy           (spi_busy),
    .done           (spi_done),
    .spi_mosi       (SPI_MOSI),
    .spi_miso       (SPI_MISO),
    .spi_sck        (SPI_SCK),
    .spi_cs_n       (SPI_CS_N)
);

//------------------------------------------------------
// AHB address phase decode
//------------------------------------------------------
assign access       = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE); // FIXME - look the 4 AHB transfer types.
assign read_enable  = access && ~HWRITE;
assign word_address = access ? HADDR[4:2] : '0;
assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

//------------------------------------------------------
// Status
//------------------------------------------------------
assign status_busy     = spi_busy;
assign status_tx_full  = tx_full;
assign status_tx_empty = tx_empty;
assign status_rx_full  = rx_full;
assign status_rx_empty = rx_empty;

assign status_tx_level = 3'd0;
assign status_rx_level = 3'd0;

//------------------------------------------------------
// IRQ 
//------------------------------------------------------
assign irq =
    (int_done    && ctrl_ie_done) ||
    ((int_overrun || int_underrun || int_cfg_err) && ctrl_ie_err);


//------------------------------------------------------
// AHB pipeline register 
//------------------------------------------------------
always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn) begin
        write_enable   <= '0;
        read_enable_r  <= '0;
        word_address_r <= '0;
        byte_select_r  <= '0;
        hwdata_r       <= '0;
    end else begin
        write_enable   <= access && HWRITE;
        read_enable_r  <= read_enable;
        word_address_r <= word_address;
        byte_select_r  <= byte_select;
        if (access && HWRITE)
            hwdata_r <= HWDATA;
    end
end

//------------------------------------------------------
// Register write 
//------------------------------------------------------
always_ff @(posedge HCLK, negedge HRESETn) begin
    if (!HRESETn) begin
        ctrl_cpha      <= 1'b0;
        ctrl_cpol      <= 1'b0;
        ctrl_clk_div   <= '1;
        ctrl_ie_done   <= 1'b0;
        ctrl_ie_err    <= 1'b0;

        cmd_start      <= 1'b0;
        cmd_opcode     <= 8'h00;
        cmd_en         <= 1'b0;
        cmd_addr_en    <= 1'b0;
        cmd_addr_bytes <= 2'b00;
        cmd_data_en    <= 1'b0;
        cmd_dir        <= 1'b0;
        cmd_dummy      <= 5'b00000;
        cmd_len        <= 8'h00;

        spi_addr       <= 32'h0;
        
        rx_last_data   <= 8'h0;

        int_done       <= 1'b0;
        int_overrun    <= 1'b0;
        int_underrun   <= 1'b0;
        int_cfg_err    <= 1'b0;
    end else begin

        // Latch DONE 
        if (spi_done)
            int_done <= 1'b1;

        if (write_enable)
            unique case (word_address_r)

                // CTRL 
                ADDR_CTRL: begin
                    if (byte_select_r[0]) begin
                        if (spi_busy || (hwdata_r[0] != hwdata_r[1])) begin
                            int_cfg_err <= 1'b1;
                        end else begin
                            ctrl_cpha    <= hwdata_r[0];
                            ctrl_cpol    <= hwdata_r[1];
                            ctrl_clk_div <= hwdata_r[9:2];
                            ctrl_ie_done <= hwdata_r[14];
                            ctrl_ie_err  <= hwdata_r[15];
                        end
                    end
                end

                // CMD 
                ADDR_CMD: begin
                    if (byte_select_r[0]) begin
                        if (spi_busy) begin
                            int_cfg_err <= 1'b1;
                        end
                        else begin
                            cmd_start      <= hwdata_r[0];
                            cmd_opcode     <= hwdata_r[8:1];
                            cmd_en         <= hwdata_r[9];
                            cmd_addr_en    <= hwdata_r[10];
                            cmd_addr_bytes <= hwdata_r[12:11];
                            cmd_data_en    <= hwdata_r[13];
                            cmd_dir        <= hwdata_r[14];
                            cmd_dummy      <= hwdata_r[19:15];
                            cmd_len        <= hwdata_r[27:20];
                        end
                    end
                end

                // INT
                ADDR_INT: begin
                    if (byte_select_r[0]) begin
                        if (hwdata_r[0]) int_done     <= 1'b0;
                        if (hwdata_r[1]) int_overrun  <= 1'b0;
                        if (hwdata_r[2]) int_underrun <= 1'b0;
                        if (hwdata_r[3]) int_cfg_err  <= 1'b0;
                    end
                end
                // ADDR
                ADDR_ADDR: begin
                    spi_addr <= hwdata_r;
                end

                // DATA write
                ADDR_DATA: begin
                    if (tx_full)
                        int_overrun <= 1'b1;
                end

                default: begin end
            endcase

        // RX read 
        if (read_enable_r && (word_address_r == ADDR_DATA)) begin
            if (rx_empty) begin
                int_underrun <= 1'b1;
            end else begin
                rx_last_data <= rx_data;
            end
        end

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
          16'b0,
          ctrl_ie_err,
          ctrl_ie_done,
          4'b0,
          ctrl_clk_div,
          ctrl_cpol,
          ctrl_cpha
      };

      ADDR_CMD: HRDATA = {
          4'b0,
          cmd_len,
          cmd_dummy,
          cmd_dir,
          cmd_data_en,
          cmd_addr_bytes,
          cmd_addr_en,
          cmd_en,
          cmd_opcode,
          1'b0
      };

      ADDR_STATUS: HRDATA = {
        21'b0, // FIX - needs to add to 32 bits
        status_rx_level,
        status_tx_level,
        status_rx_full,
        status_rx_empty,
        status_tx_full,
        status_tx_empty,
        status_busy
      };

      ADDR_INT: HRDATA = {
          28'b0,
          int_cfg_err,
          int_underrun,
          int_overrun,
          int_done
      };

      ADDR_ADDR: HRDATA = spi_addr;

      // DATA read 
      ADDR_DATA: HRDATA = rx_empty
          ? {{(DATA_WIDTH-8){1'b0}}, rx_last_data}
          : {{(DATA_WIDTH-8){1'b0}}, rx_data};

      default: HRDATA = '0;

    endcase
end

//------------------------------------------------------
// Invalid access detection
//------------------------------------------------------

always_comb begin
    invalid_access = 1'b0;

    if (write_enable) begin
        unique case (word_address_r)
            ADDR_STATUS: invalid_access = 1'b1;
            3'd6:        invalid_access = 1'b1;
            3'd7:        invalid_access = 1'b1;
            default:     invalid_access = 1'b0;
        endcase
    end
end

assign HREADYOUT = 1'b1;
// FIMXE - add a protocol-correct 2-stage error response for invalid access and cfg_error_access
assign HRESP     = invalid_access || cfg_error_access;

endmodule
