// Peripheral subsystem

module periph_ss #(
  parameter int                      ADDR_WIDTH     = 32,
  parameter int                      DATA_WIDTH     = 32,
  parameter int                      EXT_ADDR_WIDTH = 8,
  parameter int                      EXT_DATA_WIDTH = 8,
  parameter int                      NUM_GPIO       = 16
) (
  input logic                        HCLK,
  input logic                        HRESETn,

  // AHB Slave Interface (From CPU)
  input logic [ADDR_WIDTH-1:0]       HADDR,
  input logic [2:0]                  HBURST,
  input logic                        HMASTLOCK,
  input logic [3:0]                  HPROT,
  input logic [2:0]                  HSIZE,
  input logic [1:0]                  HTRANS,
  input logic [DATA_WIDTH-1:0]       HWDATA,
  input logic                        HWRITE,

  output logic [DATA_WIDTH-1:0]      HRDATA,
  output logic                       HREADY,
  output logic                       HRESP,

  // Interrupts
  output logic                       uart_rx_irq,
  output logic                       uart_rx_error_irq,

  // UART interface
  output logic                       uart_tx,
  input  logic                       uart_rx,

  // GPIO pin control interface
  input  wire [NUM_GPIO-1:0]         gpio_in,                 
  output wire [NUM_GPIO-1:0]         gpio_out,                 
  output wire [NUM_GPIO-1:0]         gpio_oe,                  
  output wire [NUM_GPIO-1:0]         gpio_cs,               
  output wire [NUM_GPIO-1:0]         gpio_sl,                 
  output wire [NUM_GPIO-1:0]         gpio_ie,               
  output wire [NUM_GPIO-1:0]         gpio_pu,
  output wire [NUM_GPIO-1:0]         gpio_pd,
  output wire [NUM_GPIO-1:0]         gpio_sync_en_n,

  // CPU instruction trace (only consumed by ahb_debug under DEBUG_PERIPH)

  /* verilator lint_off UNUSED */
  input  logic                       trace_valid,
  input  logic [35:0]                trace_data,
  /* verilator lint_on UNUSED */

  // External AHB master interface
  output logic [EXT_ADDR_WIDTH-1:0]  ext_HADDR,
  output logic [2:0]                 ext_HBURST,
  output logic                       ext_HMASTLOCK,
  output logic [3:0]                 ext_HPROT,
  output logic [2:0]                 ext_HSIZE,
  output logic [1:0]                 ext_HTRANS,
  output logic [EXT_DATA_WIDTH-1:0]  ext_HWDATA,
  output logic                       ext_HWRITE,

  input  logic [EXT_DATA_WIDTH-1:0]  ext_HRDATA,
  input  logic                       ext_HREADY,
  input  logic                       ext_HRESP
);

  // ---- AHBlite interfaces ------------------------------------------------------------
  
  ahb3lite_intf ahb_rom        ();
  ahb3lite_intf ahb_ram        ();
  ahb3lite_intf ahb_uart       ();

  ahb3lite_intf ahb_gpio_ctrl  ();  // FIXME - slot wired to ahb_stub_slave
  ahb3lite_intf ahb_qpsi       ();  // FIXME - slot wired to ahb_stub_slave
  ahb3lite_intf ahb_spi_m      ();  // FIXME - slot wired to ahb_stub_slave
  ahb3lite_intf ahb_spi_s      ();     

  ahb3lite_intf ahb_ext_periph ();

`ifdef DEBUG_PERIPH
  ahb3lite_intf ahb_debug      ();
`endif

// --- Internal Signals -----------------------------------------------------------------

logic mux_spi_s_ss_i;      // internal signal for SPI slave chip select
logic mux_spi_s_sck_i;     // internal signal for SPI slave clock
logic mux_spi_s_mosi_i;    // internal signal for SPI slave master out slave in
logic mux_spi_s_miso_o;    // internal signal for SPI slave master in slave out

//--- Interconnect ----------------------------------------------------------------------

  ahb_interconnect_ss #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_interconnect (

    // Clock and Reset
    .HCLK             (HCLK),
    .HRESETn          (HRESETn),
   
    // CPU Slave interface
    .HADDR            (HADDR),
    .HBURST           (HBURST),
    .HMASTLOCK        (HMASTLOCK),
    .HPROT            (HPROT),
    .HSIZE            (HSIZE),
    .HTRANS           (HTRANS),
    .HWDATA           (HWDATA),
    .HWRITE           (HWRITE),
    .HRDATA           (HRDATA),
    .HREADY           (HREADY),
    .HRESP            (HRESP),

    // Peripheral Master Interfaces 
    .ahb_rom_m        (ahb_rom.master),
    .ahb_ram_m        (ahb_ram.master),
    .ahb_uart_m       (ahb_uart.master),
    .ahb_gpio_ctrl_m  (ahb_gpio_ctrl.master),
    .ahb_qpsi_m       (ahb_qpsi.master),
    .ahb_spi_m_m      (ahb_spi_m.master),
    .ahb_spi_s_m      (ahb_spi_s.master),

  `ifdef DEBUG_PERIPH
    .ahb_debug_m      (ahb_debug.master),
  `endif

    .ahb_ext_periph_m (ahb_ext_periph.master)
  );

//--- ROM ------------------------------------------------------------------------------

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

  //--- RAM ------------------------------------------------------------------------------

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

  //--- UART ------------------------------------------------------------------------------

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

  //--- QSPI -----------------------------------------------------------------------------

  // FIXME - replace with actual QSPI peripheral
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_qspi_stub (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_qpsi.HADDR),
    .HBURST       (ahb_qpsi.HBURST),
    .HMASTLOCK    (ahb_qpsi.HMASTLOCK),
    .HPROT        (ahb_qpsi.HPROT),
    .HSIZE        (ahb_qpsi.HSIZE),
    .HTRANS       (ahb_qpsi.HTRANS),
    .HWDATA       (ahb_qpsi.HWDATA),
    .HWRITE       (ahb_qpsi.HWRITE),
    .HRDATA       (ahb_qpsi.HRDATA),
    .HREADYOUT    (ahb_qpsi.HREADYOUT),
    .HRESP        (ahb_qpsi.HRESP),
    .HREADYIN     (ahb_qpsi.HREADYIN),
    .HSEL         (ahb_qpsi.HSEL)
  );

  //--- SPI Master ------------------------------------------------------------------------
  
  // FIXME - replace with actual SPI Master peripheral
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_spi_m_stub (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ahb_spi_m.HADDR),
    .HBURST       (ahb_spi_m.HBURST),
    .HMASTLOCK    (ahb_spi_m.HMASTLOCK),
    .HPROT        (ahb_spi_m.HPROT),
    .HSIZE        (ahb_spi_m.HSIZE),
    .HTRANS       (ahb_spi_m.HTRANS),
    .HWDATA       (ahb_spi_m.HWDATA),
    .HWRITE       (ahb_spi_m.HWRITE),
    .HRDATA       (ahb_spi_m.HRDATA),
    .HREADYOUT    (ahb_spi_m.HREADYOUT),
    .HRESP        (ahb_spi_m.HRESP),
    .HREADYIN     (ahb_spi_m.HREADYIN),
    .HSEL         (ahb_spi_m.HSEL)
  );

  //--- SPI Slave -------------------------------------------------------------------------
 
  ahb_spi_s #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_spi_s (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),

    .HADDR        (ahb_spi_s.HADDR),
    .HBURST       (ahb_spi_s.HBURST),
    .HMASTLOCK    (ahb_spi_s.HMASTLOCK),
    .HPROT        (ahb_spi_s.HPROT),
    .HSIZE        (ahb_spi_s.HSIZE),
    .HTRANS       (ahb_spi_s.HTRANS),
    .HWDATA       (ahb_spi_s.HWDATA),
    .HWRITE       (ahb_spi_s.HWRITE),
    .HRDATA       (ahb_spi_s.HRDATA),
    .HREADYOUT    (ahb_spi_s.HREADYOUT),
    .HRESP        (ahb_spi_s.HRESP),
    .HREADYIN     (ahb_spi_s.HREADYIN),
    .HSEL         (ahb_spi_s.HSEL),

    // TODO - add IRQs

    .spi_ss       (mux_spi_s_ss_i),
    .spi_sck      (mux_spi_s_sck_i),
    .spi_mosi     (mux_spi_s_mosi_i),
    .spi_miso     (mux_spi_s_miso_o)
  );

  //--- Input/Output Subsystem (GPIO MUX) -----------------------------------------------------------------

  io_ss #(
    .ADDR_WIDTH      (ADDR_WIDTH),
    .DATA_WIDTH      (DATA_WIDTH),
    .NUM_GPIO        (NUM_GPIO)

  ) u_io_ss (
    .HCLK            (HCLK),
    .HRESETn         (HRESETn),

    .HADDR           (ahb_gpio_ctrl.HADDR),
    .HBURST          (ahb_gpio_ctrl.HBURST),
    .HMASTLOCK       (ahb_gpio_ctrl.HMASTLOCK),
    .HPROT           (ahb_gpio_ctrl.HPROT),
    .HSIZE           (ahb_gpio_ctrl.HSIZE),
    .HTRANS          (ahb_gpio_ctrl.HTRANS),
    .HWDATA          (ahb_gpio_ctrl.HWDATA),
    .HWRITE          (ahb_gpio_ctrl.HWRITE),
    .HRDATA          (ahb_gpio_ctrl.HRDATA),
    .HREADYOUT       (ahb_gpio_ctrl.HREADYOUT),
    .HRESP           (ahb_gpio_ctrl.HRESP),
    .HREADYIN        (ahb_gpio_ctrl.HREADYIN),
    .HSEL            (ahb_gpio_ctrl.HSEL),

    // Serial Interface Signals
    .spi_s_ss_i      (mux_spi_s_ss_i),
    .spi_s_sck_i     (mux_spi_s_sck_i),
    .spi_s_mosi_i    (mux_spi_s_mosi_i),
    .spi_s_miso_o    (mux_spi_s_miso_o),

    // FIXME - tied off until the SPI master and QSPI peripherals are implemented
    .spi_m_sck_o     (1'b0),
    .spi_m_mosi_o    (1'b0),
    .spi_m_miso_i    (),
    .spi_m_ss_o      (1'b1),

    .qspi_sck_o      (1'b0),
    .qspi_ce_n_o     (2'b11),
    .qspi_sio_i      (),
    .qspi_sio_o      (4'b0),
    .qspi_sio_oe     (4'b0),

    // GPIO pin control interface
    .gpio_in         (gpio_in),
    .gpio_out        (gpio_out),
    .gpio_oe         (gpio_oe),
    .gpio_cs         (gpio_cs),
    .gpio_sl         (gpio_sl),
    .gpio_ie         (gpio_ie),
    .gpio_pu         (gpio_pu),
    .gpio_pd         (gpio_pd),
    .gpio_sync_en_n  (gpio_sync_en_n)
  );

  //--- External Peripheral -------------------------------------------------------------------------

  assign ext_HADDR     = ahb_ext_periph.HADDR;
  assign ext_HBURST    = ahb_ext_periph.HBURST;
  assign ext_HMASTLOCK = ahb_ext_periph.HMASTLOCK;
  assign ext_HPROT     = ahb_ext_periph.HPROT;
  assign ext_HSIZE     = ahb_ext_periph.HSIZE;
  assign ext_HTRANS    = ahb_ext_periph.HTRANS;
  assign ext_HWDATA    = ahb_ext_periph.HWDATA;
  assign ext_HWRITE    = ahb_ext_periph.HWRITE;
  assign ahb_ext_periph.HRDATA    = ext_HRDATA;
  assign ahb_ext_periph.HREADYOUT = ext_HREADY;
  assign ahb_ext_periph.HRESP     = ext_HRESP;

  //--- Debug Peripheral -------------------------------------------------------------------------
  // Only instantiated if DEBUG_PERIPH is defined, otherwise the trace signals are unused.

`ifdef DEBUG_PERIPH
  ahb_debug #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
  `ifdef CPU_TRACE
    .TRACE_EN   (1'b1)
  `else
    .TRACE_EN   (1'b0)
  `endif
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
    .HSEL         (ahb_debug.HSEL),

    .trace_valid  (trace_valid),
    .trace_data   (trace_data)
  );
`endif

endmodule
