
module uart_wtb;

  timeunit 1ns/1ps;

  // AHB Signals
  logic         HCLK;
  logic         HRESETn;
  logic [31:0]  HADDR;
  logic [2:0]   HBURST;
  logic         HMASTLOCK;
  logic [3:0]   HPROT;
  logic [2:0]   HSIZE;
  logic [1:0]   HTRANS;
  logic [31:0]  HWDATA;
  logic         HWRITE;
  logic [31:0]  HRDATA;
  logic         HREADYOUT;
  logic         HRESP;
  logic         HREADYIN;
  logic         HSEL;

  // UART Signals
  wire logic    uart_tx;
  logic         uart_rx;
  wire logic    rx_irq;
  wire logic    rx_error_irq;

  ahb_uart #(
    .ADDR_WIDTH      (32),
    .DATA_WIDTH      (32)
  ) u_ahb_uart (
    .HCLK            (HCLK),
    .HRESETn         (HRESETn),
    // AHB Slave Interface
    // Master Signals
    .HADDR           (HADDR),
    .HBURST          (HBURST),
    .HMASTLOCK       (HMASTLOCK),
    .HPROT           (HPROT),
    .HSIZE           (HSIZE),
    .HTRANS          (HTRANS),
    .HWDATA          (HWDATA),
    .HWRITE          (HWRITE),
    // Slave Signals
    .HRDATA          (HRDATA),
    .HREADYOUT       (HREADYOUT),
    .HRESP           (HRESP),
    // Decoder Signals
    .HREADYIN        (HREADYIN),
    .HSEL            (HSEL),
    // Interrupts
    .rx_irq          (rx_irq),
    .rx_error_irq    (rx_error_irq),
    // UART interface
    .uart_tx         (uart_tx),
    .uart_rx         (uart_rx)
  );

endmodule