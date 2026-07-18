module picorv32_hello_core #(
  parameter real CLK_FREQ = 10e6
) (
  input logic clk,
  input logic rst_n,

  // UART interface
  output logic                  uart_tx,
  input  logic                  uart_rx
);
  localparam int ADDR_WIDTH = 32;
  localparam int DATA_WIDTH = 32;

  // AHB from CPU to Periph SS
  logic [ADDR_WIDTH-1:0]  HADDR;
  logic [2:0]             HBURST;
  logic                   HMASTLOCK;
  logic [3:0]             HPROT;
  logic [2:0]             HSIZE;
  logic [1:0]             HTRANS;
  logic [DATA_WIDTH-1:0]  HWDATA;
  logic                   HWRITE;

  // Slave Signals
  logic [DATA_WIDTH-1:0]  HRDATA;
  logic                   HREADY;
  logic                   HRESP;

  // Interrupts
  logic                   uart_rx_irq;
  logic                   uart_rx_error_irq;

  cpu_ss #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_IRQ    (2)
  ) u_cpu_ss (
    .HCLK       (clk),
    .HRESETn    (rst_n),
    .HADDR      (HADDR),
    .HBURST     (HBURST),
    .HMASTLOCK  (HMASTLOCK),
    .HPROT      (HPROT),
    .HSIZE      (HSIZE),
    .HTRANS     (HTRANS),
    .HWDATA     (HWDATA),
    .HWRITE     (HWRITE),
    .HRDATA     (HRDATA),
    .HREADY     (HREADY),
    .HRESP      (HRESP),
    .irq        ({
      uart_rx_error_irq,
      uart_rx_irq
    })
  );

  periph_ss #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_periph_ss (
    .HCLK               (clk),
    .HRESETn            (rst_n),
    .HADDR              (HADDR),
    .HBURST             (HBURST),
    .HMASTLOCK          (HMASTLOCK),
    .HPROT              (HPROT),
    .HSIZE              (HSIZE),
    .HTRANS             (HTRANS),
    .HWDATA             (HWDATA),
    .HWRITE             (HWRITE),
    .HRDATA             (HRDATA),
    .HREADY             (HREADY),
    .HRESP              (HRESP),
    .uart_rx_irq        (uart_rx_irq),
    .uart_rx_error_irq  (uart_rx_error_irq),
    .uart_tx            (uart_tx),
    .uart_rx            (uart_rx)
  );

endmodule
