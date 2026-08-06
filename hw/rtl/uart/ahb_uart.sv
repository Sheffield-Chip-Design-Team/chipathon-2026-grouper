// AHB UART 


module ahb_uart #(
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

  // Interrupts
  output logic                  rx_irq,
  output logic                  rx_error_irq,

  // UART interface
  output logic                  uart_tx,
  input  logic                  uart_rx
);

  import ahb3lite_pkg::*;

  localparam int CLK_DIV_BITS = 10;
  localparam int UART_DATA_W = 8;

  localparam bit [1:0] ADDR_CTRL    = 2'b00;
  localparam bit [1:0] ADDR_STATUS  = 2'b01;
  localparam bit [1:0] ADDR_TXDATA  = 2'b10;
  localparam bit [1:0] ADDR_RXDATA  = 2'b11;
  
  // Control registers
  logic                     ctrl_enable;
  logic [CLK_DIV_BITS-1:0]  ctrl_clk_div;
  logic                     ctrl_tx_en;
  logic                     ctrl_rx_en;
  logic                     ctrl_rx_resync_en;
  logic                     ctrl_tx_break;
  logic                     ctrl_flush_tx_fifo;    // WOSC
  logic                     ctrl_flush_rx_fifo;    // WOSC

  
  // Status registers
  logic                     status_tx_empty;
  logic                     status_tx_full;
  logic                     status_rx_empty;
  logic                     status_rx_full;
  logic                     status_tx_active;
  logic                     status_rx_frame_error;  // RC
  logic                     status_rx_break;        // RC
  
  // Control signals
  logic                     rx_frame_error; // 1-cycle pulse on frame error
  logic                     rx_break;       // High when in a break condition

  // Fifo signals
  logic [UART_DATA_W-1:0]   tx_data;
  logic                     tx_write;
  logic [UART_DATA_W-1:0]   rx_data;
  logic                     rx_read;

  //control signals are stored in registers
  logic                       access;
  logic                       read_enable;
  logic                       read_enable_r;
  logic                       write_enable;
  logic [1:0]                 word_address;
  logic [1:0]                 word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;

  logic                       invalid_access;
  logic                       read_invalid;     // decided in the address phase
  logic                       read_invalid_r;   // ...consumed in the data phase
  logic                       hresp_err_req_r;  // second cycle of an ERROR response

  // Instance the uart core
  uart #(
    .CLK_DIV_BITS (CLK_DIV_BITS),
    .DATA_WIDTH   (UART_DATA_W)
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

  assign rx_error_irq = rx_frame_error;

  //Generate the control signals in the address phase
  assign access       = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);
  assign read_enable  = access && ~HWRITE;

  assign word_address = access ? HADDR[3:2] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

  assign rx_read = read_enable && !status_rx_empty && word_address == ADDR_RXDATA;

  assign read_invalid = read_enable && (word_address == ADDR_RXDATA) && status_rx_empty;

  // Delay write control signals to data phase.
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      write_enable    <= '0;
      read_enable_r   <= '0;
      word_address_r  <= '0;
      byte_select_r   <= '0;
      read_invalid_r  <= '0;
    end else if (HREADYOUT) begin
      write_enable    <= access && HWRITE;
      read_enable_r   <= read_enable;
      word_address_r  <= word_address;
      byte_select_r   <= byte_select;
      read_invalid_r  <= read_invalid;
    end

  //Act on control signals in the data phase
  // write
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      ctrl_enable         <= '0;
      ctrl_clk_div        <= '1;
      ctrl_tx_en          <= '0;
      ctrl_rx_en          <= '0;
      ctrl_rx_resync_en   <= '1;
      ctrl_tx_break       <= '0;
      ctrl_flush_tx_fifo  <= '0;
      ctrl_flush_rx_fifo  <= '0;
    end else begin
      ctrl_flush_tx_fifo <= '0; // Clear after 1 clock cycle
      ctrl_flush_rx_fifo <= '0; // Clear after 1 clock cycle
      if (write_enable)
        unique case (word_address_r)
          ADDR_CTRL: begin
            if (byte_select_r[0]) begin
              ctrl_enable         <= HWDATA[0];
              ctrl_tx_en          <= HWDATA[1];
              ctrl_rx_en          <= HWDATA[2];
              ctrl_rx_resync_en   <= HWDATA[3];
              ctrl_tx_break       <= HWDATA[4];
              ctrl_flush_tx_fifo  <= HWDATA[5];
              ctrl_flush_rx_fifo  <= HWDATA[6];
              ctrl_clk_div        <= HWDATA[16 +: CLK_DIV_BITS];
            end
          end
          default: begin end
        endcase
    end

  // Take the ceil of data width / 8
  assign tx_write = !status_tx_full && (
    write_enable && word_address_r == ADDR_TXDATA && &(byte_select_r[0 +: (UART_DATA_W+7)/8])
  );
  assign tx_data  = HWDATA[0 +: UART_DATA_W];

  // read
always_comb begin
  if (!read_enable_r)
    // (output of zero when not enabled for read is not necessary
    //  but may help with debugging)
    HRDATA = '0;
  else
    unique case (word_address_r)
      ADDR_CTRL: HRDATA = {
        {(16-CLK_DIV_BITS){1'b0}},
        ctrl_clk_div,
        11'b0,
        ctrl_tx_break,
        ctrl_rx_resync_en,
        ctrl_rx_en,
        ctrl_tx_en,
        ctrl_enable
      };
      ADDR_STATUS: HRDATA = {
        25'b0,
        status_rx_break,
        status_rx_frame_error,
        status_tx_active,
        status_rx_full,
        status_rx_empty,
        status_tx_full,
        status_tx_empty
      };
      ADDR_RXDATA: HRDATA = {
        {(32-UART_DATA_W){1'b0}},
        rx_data
      };
      default: HRDATA = '0;
    endcase
  end

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      status_rx_frame_error <= '0;
      status_rx_break <= '0;
    end else begin
      if (read_enable_r && word_address_r == ADDR_STATUS && byte_select_r[0]) begin
        status_rx_frame_error <= '0;
        status_rx_break <= '0;
      end

      if (rx_frame_error)
        status_rx_frame_error <= '1;
      if (rx_break)
        status_rx_break <= '1;
    end

  //Transfer Response

  // Everything here is data phase. The write terms are naturally so
  // (write_enable, word_address_r and status_tx_full all are); the read term
  // arrives pre-decided from the address phase
  always_comb begin
    invalid_access = read_invalid_r;

    if (write_enable)
      unique case (word_address_r)
        ADDR_STATUS: invalid_access |= '1;
        ADDR_TXDATA: invalid_access |= status_tx_full;
        ADDR_RXDATA: invalid_access |= '1;
        default: begin end
      endcase
  end

  always_ff @(posedge HCLK or negedge HRESETn)
    if (!HRESETn) hresp_err_req_r <= 1'b0;
    else          hresp_err_req_r <= invalid_access && !hresp_err_req_r;

  // Low for the first cycle and high for the second, HRESP high for both.
  assign HREADYOUT = !(invalid_access && !hresp_err_req_r);
  assign HRESP     =   invalid_access || hresp_err_req_r;

endmodule

