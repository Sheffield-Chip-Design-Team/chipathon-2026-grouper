// AHB spi_s


module ahb_spi_s #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

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

  //SPI interface
  input logic                   spi_ss,
  input logic                   spi_sck,
  input logic                   spi_mosi,
  output logic                  spi_miso
);

  import ahb3lite_pkg::*;
  localparam int SPI_S_DATA_W = 8;

  // AHB transfer codes needed in this module
  localparam bit [1:0] No_Transfer  = 2'b00;
  

  localparam bit [1:0] ADDR_CTRL    = 2'b00;
  localparam bit [1:0] ADDR_STATUS  = 2'b01;
  localparam bit [1:0] ADDR_TXDATA  = 2'b10;
  localparam bit [1:0] ADDR_RXDATA  = 2'b11;
  
  // Control registers
  logic                     ctrl_enable;
  logic                     ctrl_soft_reset;
  
  // Status registers
  logic                     status_busy;
  logic                     status_rx_valid;
  logic                     status_tx_ready;
  
  // SPI data registers
  logic [SPI_S_DATA_W-1:0]   tx_data;
  logic [SPI_S_DATA_W-1:0]   rx_data;

  //control signals are stored in registers
  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;
  logic [1:0]                 word_address;
  logic [1:0]                 word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;
  logic invalid_access;

  // Instance the uart core
  /*uart #(
    .CLK_DIV_BITS (CLK_DIV_BITS),
    .DATA_WIDTH   (SPI_S_DATA_W)
  ) u_uart (
      .clk            (HCLK),
      .rst_n          (HRESETn),
      .enable         (ctrl_enable),
      .clk_div        (ctrl_clk_div),
      .tx_en          (ctrl_tx_en),
      .rx_en          (ctrl_rx_en),
      .rx_resync_en   (ctrl_rx_resync_en),
      .tx_break       (ctrl_tx_break),
      .tx_active      (status_tx_active),
      .received       (rx_irq),
      .rx_frame_error (rx_frame_error),
      .rx_break       (rx_break),
      .flush_tx_fifo  (ctrl_flush_tx_fifo),
      .tx_data        (tx_data),
      .tx_write       (tx_write),
      .tx_full        (status_tx_full),
      .tx_empty       (status_tx_empty),
      .flush_rx_fifo  (ctrl_flush_rx_fifo),
      .rx_read        (rx_read),
      .rx_full        (status_rx_full),
      .rx_empty       (status_rx_empty),
      .rx_data        (rx_data),
      .uart_tx        (uart_tx),
      .uart_rx        (uart_rx)
  );
*/


  //Generate the control signals in the address phase
  assign access       = HREADYIN && HSEL && (HTRANS != No_Transfer);
  assign read_enable  = access && ~HWRITE;

  // Temporary values until the SPI core is implemented.
  assign status_busy     = 1'b0;
  assign status_rx_valid = 1'b0;
  assign status_tx_ready = 1'b1;
  //assign rx_data         = 8'h00;

  assign word_address = access ? HADDR[3:2] : '0;
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
      ctrl_enable         <= '0;
      ctrl_soft_reset         <= '0;
      tx_data        <= '0;
    end else begin

      if (write_enable)
        unique case (word_address_r)
          ADDR_CTRL: begin
            if (byte_select_r[0]) begin
              ctrl_enable         <= HWDATA[0];
              ctrl_soft_reset     <= HWDATA[1];
            end
          end

          ADDR_TXDATA: begin
            tx_data <= HWDATA[7:0];
          end

          default: begin end
        endcase
    end

  // read registers
  always_comb
    if (!read_enable_r)
      // (output of zero when not enabled for read is not necessary
      //  but may help with debugging)
      HRDATA = '0;
    else
      unique case (word_address_r)
      
        // CTRL register (0x00)
        ADDR_CTRL:
        HRDATA = { 
          30'b0,
          ctrl_soft_reset,
          ctrl_enable
        };
        
        // STATUS register (0x04)
        ADDR_STATUS: 
        HRDATA = {
          29'b0,
          status_tx_ready,
          status_rx_valid,
          status_busy
        };
          
        // RXDATA register (0x0C)
        ADDR_RXDATA:
        HRDATA = {
          24'b0,
          rx_data
        };
            
        default: HRDATA = '0;
      endcase

  //Transfer Response
  always_comb begin
    invalid_access = '0;

    if (write_enable)
      unique case (word_address_r)
        ADDR_STATUS: invalid_access |= '1; //STATUS is read-only
        ADDR_RXDATA: invalid_access |= '1; //RXDATA is read-only
        default: begin end
      endcase
  end

  // Single cycle Write & Read. Zero Wait state operations
  assign HREADYOUT = '1;

  // FIXME - add 2-cycle error response for invalid access.
  assign HRESP = invalid_access ? 1'b1 : 1'b0;

endmodule

