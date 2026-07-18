module periph_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic HCLK,
  input logic HRESETn,

  // AHB Slave Interface
  // Don't use interfaces at hierarchy boundaries for better conversion to verilog
  
  // Master Signals
  input logic [ADDR_WIDTH-1:0] HADDR,
  input logic [2:0]            HBURST,
  input logic                  HMASTLOCK,
  input logic [3:0]            HPROT,
  input logic [2:0]            HSIZE,
  input logic [1:0]            HTRANS,
  input logic [DATA_WIDTH-1:0] HWDATA,
  input logic                  HWRITE,

  // Slave Signals
  output logic [DATA_WIDTH-1:0]  HRDATA,
  output logic                   HREADY,
  output logic                   HRESP,

  // Interrupts
  output logic                  uart_rx_irq,
  output logic                  uart_rx_error_irq,

  // UART interface
  output logic                  uart_tx,
  input  logic                  uart_rx
);

  ahb3lite_intf ahb_rom();
  ahb3lite_intf ahb_ram();
  ahb3lite_intf ahb_uart();
`ifdef DEBUG_PERIPH
  ahb3lite_intf ahb_debug();
`endif

  ahb_interconnect #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_interconnect (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .ahb_rom_m    (ahb_rom.master),
    .ahb_ram_m    (ahb_ram.master),
    .ahb_uart_m    (ahb_uart.master),
`ifdef DEBUG_PERIPH
    .ahb_debug_m  (ahb_debug.master),
`endif
    .HADDR        (HADDR),
    .HBURST       (HBURST),
    .HMASTLOCK    (HMASTLOCK),
    .HPROT        (HPROT),
    .HSIZE        (HSIZE),
    .HTRANS       (HTRANS),
    .HWDATA       (HWDATA),
    .HWRITE       (HWRITE),
    .HRDATA       (HRDATA),
    .HREADY       (HREADY),
    .HRESP        (HRESP)
  );

  ahb_rom #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_rom (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_rom.HADDR),
    .HBURST       (ahb_rom.HBURST),
    .HMASTLOCK    (ahb_rom.HMASTLOCK),
    .HPROT        (ahb_rom.HPROT),
    .HSIZE        (ahb_rom.HSIZE),
    .HTRANS       (ahb_rom.HTRANS),
    .HWDATA       (ahb_rom.HWDATA),
    .HWRITE       (ahb_rom.HWRITE),
    .HRDATA       (ahb_rom.HRDATA),
    .HREADYOUT    (ahb_rom.HREADYOUT),
    .HRESP        (ahb_rom.HRESP),
    .HREADYIN     (ahb_rom.HREADYIN),
    .HSEL         (ahb_rom.HSEL)
  );

  ahb_ram #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_ram (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_ram.HADDR),
    .HBURST       (ahb_ram.HBURST),
    .HMASTLOCK    (ahb_ram.HMASTLOCK),
    .HPROT        (ahb_ram.HPROT),
    .HSIZE        (ahb_ram.HSIZE),
    .HTRANS       (ahb_ram.HTRANS),
    .HWDATA       (ahb_ram.HWDATA),
    .HWRITE       (ahb_ram.HWRITE),
    .HRDATA       (ahb_ram.HRDATA),
    .HREADYOUT    (ahb_ram.HREADYOUT),
    .HRESP        (ahb_ram.HRESP),
    .HREADYIN     (ahb_ram.HREADYIN),
    .HSEL         (ahb_ram.HSEL)
  );

  ahb_uart #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_uart (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_uart.HADDR),
    .HBURST       (ahb_uart.HBURST),
    .HMASTLOCK    (ahb_uart.HMASTLOCK),
    .HPROT        (ahb_uart.HPROT),
    .HSIZE        (ahb_uart.HSIZE),
    .HTRANS       (ahb_uart.HTRANS),
    .HWDATA       (ahb_uart.HWDATA),
    .HWRITE       (ahb_uart.HWRITE),
    .HRDATA       (ahb_uart.HRDATA),
    .HREADYOUT    (ahb_uart.HREADYOUT),
    .HRESP        (ahb_uart.HRESP),
    .HREADYIN     (ahb_uart.HREADYIN),
    .HSEL         (ahb_uart.HSEL),
    .rx_irq       (uart_rx_irq),
    .rx_error_irq (uart_rx_error_irq),
    .uart_tx      (uart_tx),
    .uart_rx      (uart_rx)
  );

`ifdef DEBUG_PERIPH
  ahb_debug #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_debug (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_debug.HADDR),
    .HBURST       (ahb_debug.HBURST),
    .HMASTLOCK    (ahb_debug.HMASTLOCK),
    .HPROT        (ahb_debug.HPROT),
    .HSIZE        (ahb_debug.HSIZE),
    .HTRANS       (ahb_debug.HTRANS),
    .HWDATA       (ahb_debug.HWDATA),
    .HWRITE       (ahb_debug.HWRITE),
    .HRDATA       (ahb_debug.HRDATA),
    .HREADYOUT    (ahb_debug.HREADYOUT),
    .HRESP        (ahb_debug.HRESP),
    .HREADYIN     (ahb_debug.HREADYIN),
    .HSEL         (ahb_debug.HSEL)
  );
`endif

endmodule
