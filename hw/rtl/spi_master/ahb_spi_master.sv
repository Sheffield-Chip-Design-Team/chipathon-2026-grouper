// AHB spi master


module ahb_spi_master #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // GRPR-SPIM-001
  // AHB Slave Interface
    
  // Master Signals
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL,

   // SPI interface
  output logic                  SPI_MOSI,
  output logic                  SPI_SCK,

 
  output logic                  SPI_CS_N,
  input  logic                  SPI_MISO
);

  import ahb3lite_pkg::*;

  localparam int CLK_DIV_BITS = 8;
  localparam int SPI_DATA_W = 8;

  
  

localparam logic [2:0] ADDR_CTRL   = 3'd0;
localparam logic [2:0] ADDR_CMD    = 3'd1;
localparam logic [2:0] ADDR_STATUS = 3'd2;
localparam logic [2:0] ADDR_INT    = 3'd3;
localparam logic [2:0] ADDR_ADDR   = 3'd4;
localparam logic [2:0] ADDR_DATA   = 3'd5;

  //TARGET reg (open item in specs)
  
  // GRPR-SPIM-012
  // Control registers
logic        ctrl_cpha;
logic        ctrl_cpol;
logic [7:0] ctrl_clk_div;

logic        ctrl_lsb_first;
logic        ctrl_cs_auto;
logic        ctrl_cs_level;
logic [2:0] ctrl_cs_sel;

logic        ctrl_ie_done;
logic        ctrl_ie_err;


//CMD register 

logic        cmd_start;
logic [7:0] cmd_opcode;
logic        cmd_en;
logic        cmd_addr_en;
logic [1:0] cmd_addr_bytes;
logic        cmd_data_en;
logic        cmd_dir;
logic [4:0] cmd_dummy;
logic [7:0] cmd_len;

  
  // Status registers
 logic status_busy;

logic status_tx_empty;
logic status_tx_full;

logic status_rx_empty;
logic status_rx_full;

logic [4:0] status_tx_level;
logic [4:0] status_rx_level;


// INT register 

logic int_done;
logic int_overrun;
logic int_underrun;
logic int_cfg_err;


  // SPI registers
  logic [31:0] spi_addr;
  logic [31:0] spi_data;

  

  //control signals are stored in registers
  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;
  logic [2:0]                 word_address;
  logic [2:0]                 word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;
  logic invalid_access;

  // TODO (GRPR-SPIM-005):
// Instantiate SPI M core here

  

  //Generate the control signals in the address phase
  assign access       = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);
  assign read_enable  = access && ~HWRITE;

  assign word_address = access ? HADDR[4:2] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

  

  // Delay write control signals to data phase
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      write_enable    <= '0;
      read_enable_r   <= '0;
      word_address_r  <= '0;
      byte_select_r   <= '0;
    end else begin
      write_enable    <= access && HWRITE;
      read_enable_r   <= read_enable;
      word_address_r  <= word_address;
      byte_select_r   <= byte_select;
    end

  //Act on control signals in the data phase

  // write
  always_ff @(posedge HCLK, negedge HRESETn)
   if (~HRESETn) begin
  ctrl_cpha      <= 1'b0;
  ctrl_cpol      <= 1'b0;
  ctrl_clk_div   <= '1;

  ctrl_lsb_first <= 1'b0;
  ctrl_cs_auto   <= 1'b1;
  ctrl_cs_level  <= 1'b1;
  ctrl_cs_sel    <= 3'b000;

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
  spi_data       <= 32'h0;

  int_done       <= 1'b0;
  int_overrun    <= 1'b0;
  int_underrun   <= 1'b0;
  int_cfg_err    <= 1'b0;
end else begin
    if (write_enable)
      unique case (word_address_r)

         // CTRL register
    ADDR_CTRL: begin
      if (byte_select_r[0]) begin
        ctrl_cpha      <= HWDATA[0];
        ctrl_cpol      <= HWDATA[1];
        ctrl_clk_div   <= HWDATA[9:2];
        ctrl_lsb_first <= HWDATA[10];
        ctrl_cs_auto   <= HWDATA[11];
        ctrl_cs_level  <= HWDATA[12];
        ctrl_cs_sel    <= HWDATA[15:13];
        ctrl_ie_done   <= HWDATA[16];
        ctrl_ie_err    <= HWDATA[17];
      end
    end

    // CMD register
    ADDR_CMD: begin
      if (byte_select_r[0]) begin
        cmd_start      <= HWDATA[0 ];
        cmd_opcode     <= HWDATA[8 :1];
        cmd_en         <= HWDATA[9];
        cmd_addr_en    <= HWDATA[10];
        cmd_addr_bytes <= HWDATA[12 :11];
        cmd_data_en    <= HWDATA[13];
        cmd_dir        <= HWDATA[ 14];
        cmd_dummy      <= HWDATA[ 19:15];
        cmd_len        <= HWDATA[27:20];
      end
    end

    // INT register (write-1-to-clear)
    ADDR_INT: begin
      if (byte_select_r[0]) begin
        if (HWDATA[0] ) int_done     <= 1'b0;
        if (HWDATA  [1]) int_overrun <= 1'b0;
        if (HWDATA[2] ) int_underrun<= 1'b0;
        if (HWDATA[3] ) int_cfg_err <= 1'b0;
      end
    end

    // ADDR register
    ADDR_ADDR: begin
      spi_addr <= HWDATA;
    end

    // DATA register
    ADDR_DATA: begin
      spi_data <= HWDATA;
    end

    default: begin end

  endcase
    end
  

  

  // read
  always_comb
    if (!read_enable_r)
      
      HRDATA = '0;
    else
      unique case (word_address_r)
        ADDR_CTRL: HRDATA = {
           14'b0,
          ctrl_ie_err,
          ctrl_ie_done,
          ctrl_cs_sel,
          ctrl_cs_level,
          ctrl_cs_auto,
          ctrl_lsb_first,
          ctrl_clk_div,
          ctrl_cpol,
          ctrl_cpha
        };

      ADDR_CMD:
        HRDATA = {
          4'b0,
          cmd_len,
          cmd_dummy,
          cmd_dir,
          cmd_data_en,
          cmd_addr_bytes,
          cmd_addr_en,
          cmd_en,
          cmd_opcode,
          cmd_start
        };

      ADDR_STATUS:
        HRDATA = {
          17'b0,
          status_rx_level,
          status_tx_level,
          status_rx_full,
          status_rx_empty,
          status_tx_full,
          status_tx_empty,
          status_busy
        };

      ADDR_INT:
        HRDATA = {
          28'b0,
          int_cfg_err,
          int_underrun,
          int_overrun,
          int_done
        };

      ADDR_ADDR:
        HRDATA = spi_addr;

      ADDR_DATA:
        HRDATA = spi_data;

      default:
        HRDATA = '0;

    endcase


always_comb begin
  invalid_access = 1'b0;

  if (write_enable) begin
    unique case (word_address_r)

      // STATUS is read only
      ADDR_STATUS:
        invalid_access = 1'b1;

      default: begin end

    endcase
  end
end

  assign HREADYOUT = 1'b1; // 
  assign HRESP = invalid_access ? 1'b1 : 1'b0;

endmodule

