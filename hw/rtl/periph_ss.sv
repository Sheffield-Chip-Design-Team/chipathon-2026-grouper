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

  // ---- AHBlite peripheral buses --------------------------------------------------------
  //
  // One flat signal group per fabric slot, matching the peripheral master
  // ports on ahb_interconnect_ss. These were `ahb3lite_intf` instances; they
  // are flat because an interface cannot cross a hierarchy boundary in a
  // Verilog netlist - see the header of ahb_interconnect_ss.sv.

  logic [ADDR_WIDTH-1:0] rom_HADDR;
  logic [2:0]            rom_HBURST;
  logic                  rom_HMASTLOCK;
  logic [3:0]            rom_HPROT;
  logic [2:0]            rom_HSIZE;
  logic [1:0]            rom_HTRANS;
  logic [DATA_WIDTH-1:0] rom_HWDATA;
  logic                  rom_HWRITE;
  logic                  rom_HREADYIN;
  logic                  rom_HSEL;
  logic [DATA_WIDTH-1:0] rom_HRDATA;
  logic                  rom_HREADYOUT;
  logic                  rom_HRESP;

  logic [ADDR_WIDTH-1:0] ram_HADDR;
  logic [2:0]            ram_HBURST;
  logic                  ram_HMASTLOCK;
  logic [3:0]            ram_HPROT;
  logic [2:0]            ram_HSIZE;
  logic [1:0]            ram_HTRANS;
  logic [DATA_WIDTH-1:0] ram_HWDATA;
  logic                  ram_HWRITE;
  logic                  ram_HREADYIN;
  logic                  ram_HSEL;
  logic [DATA_WIDTH-1:0] ram_HRDATA;
  logic                  ram_HREADYOUT;
  logic                  ram_HRESP;

  logic [ADDR_WIDTH-1:0] uart_HADDR;
  logic [2:0]            uart_HBURST;
  logic                  uart_HMASTLOCK;
  logic [3:0]            uart_HPROT;
  logic [2:0]            uart_HSIZE;
  logic [1:0]            uart_HTRANS;
  logic [DATA_WIDTH-1:0] uart_HWDATA;
  logic                  uart_HWRITE;
  logic                  uart_HREADYIN;
  logic                  uart_HSEL;
  logic [DATA_WIDTH-1:0] uart_HRDATA;
  logic                  uart_HREADYOUT;
  logic                  uart_HRESP;

  logic [ADDR_WIDTH-1:0] gpio_ctrl_HADDR;
  logic [2:0]            gpio_ctrl_HBURST;
  logic                  gpio_ctrl_HMASTLOCK;
  logic [3:0]            gpio_ctrl_HPROT;
  logic [2:0]            gpio_ctrl_HSIZE;
  logic [1:0]            gpio_ctrl_HTRANS;
  logic [DATA_WIDTH-1:0] gpio_ctrl_HWDATA;
  logic                  gpio_ctrl_HWRITE;
  logic                  gpio_ctrl_HREADYIN;
  logic                  gpio_ctrl_HSEL;
  logic [DATA_WIDTH-1:0] gpio_ctrl_HRDATA;
  logic                  gpio_ctrl_HREADYOUT;
  logic                  gpio_ctrl_HRESP;

  // FIXME - slot wired to ahb_stub_slave
  logic [ADDR_WIDTH-1:0] qpsi_HADDR;
  logic [2:0]            qpsi_HBURST;
  logic                  qpsi_HMASTLOCK;
  logic [3:0]            qpsi_HPROT;
  logic [2:0]            qpsi_HSIZE;
  logic [1:0]            qpsi_HTRANS;
  logic [DATA_WIDTH-1:0] qpsi_HWDATA;
  logic                  qpsi_HWRITE;
  logic                  qpsi_HREADYIN;
  logic                  qpsi_HSEL;
  logic [DATA_WIDTH-1:0] qpsi_HRDATA;
  logic                  qpsi_HREADYOUT;
  logic                  qpsi_HRESP;

  // FIXME - slot wired to ahb_stub_slave
  logic [ADDR_WIDTH-1:0] spi_m_HADDR;
  logic [2:0]            spi_m_HBURST;
  logic                  spi_m_HMASTLOCK;
  logic [3:0]            spi_m_HPROT;
  logic [2:0]            spi_m_HSIZE;
  logic [1:0]            spi_m_HTRANS;
  logic [DATA_WIDTH-1:0] spi_m_HWDATA;
  logic                  spi_m_HWRITE;
  logic                  spi_m_HREADYIN;
  logic                  spi_m_HSEL;
  logic [DATA_WIDTH-1:0] spi_m_HRDATA;
  logic                  spi_m_HREADYOUT;
  logic                  spi_m_HRESP;

  logic [ADDR_WIDTH-1:0] spi_s_HADDR;
  logic [2:0]            spi_s_HBURST;
  logic                  spi_s_HMASTLOCK;
  logic [3:0]            spi_s_HPROT;
  logic [2:0]            spi_s_HSIZE;
  logic [1:0]            spi_s_HTRANS;
  logic [DATA_WIDTH-1:0] spi_s_HWDATA;
  logic                  spi_s_HWRITE;
  logic                  spi_s_HREADYIN;
  logic                  spi_s_HSEL;
  logic [DATA_WIDTH-1:0] spi_s_HRDATA;
  logic                  spi_s_HREADYOUT;
  logic                  spi_s_HRESP;

  logic [ADDR_WIDTH-1:0] ext_periph_HADDR;
  logic [2:0]            ext_periph_HBURST;
  logic                  ext_periph_HMASTLOCK;
  logic [3:0]            ext_periph_HPROT;
  logic [2:0]            ext_periph_HSIZE;
  logic [1:0]            ext_periph_HTRANS;
  logic [DATA_WIDTH-1:0] ext_periph_HWDATA;
  logic                  ext_periph_HWRITE;
  logic                  ext_periph_HREADYIN;
  logic                  ext_periph_HSEL;
  logic [DATA_WIDTH-1:0] ext_periph_HRDATA;
  logic                  ext_periph_HREADYOUT;
  logic                  ext_periph_HRESP;

`ifdef DEBUG_PERIPH
  logic [ADDR_WIDTH-1:0] debug_HADDR;
  logic [2:0]            debug_HBURST;
  logic                  debug_HMASTLOCK;
  logic [3:0]            debug_HPROT;
  logic [2:0]            debug_HSIZE;
  logic [1:0]            debug_HTRANS;
  logic [DATA_WIDTH-1:0] debug_HWDATA;
  logic                  debug_HWRITE;
  logic                  debug_HREADYIN;
  logic                  debug_HSEL;
  logic [DATA_WIDTH-1:0] debug_HRDATA;
  logic                  debug_HREADYOUT;
  logic                  debug_HRESP;
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

    // Peripheral master ports
    .rom_HADDR              (rom_HADDR),
    .rom_HBURST             (rom_HBURST),
    .rom_HMASTLOCK          (rom_HMASTLOCK),
    .rom_HPROT              (rom_HPROT),
    .rom_HSIZE              (rom_HSIZE),
    .rom_HTRANS             (rom_HTRANS),
    .rom_HWDATA             (rom_HWDATA),
    .rom_HWRITE             (rom_HWRITE),
    .rom_HREADYIN           (rom_HREADYIN),
    .rom_HSEL               (rom_HSEL),
    .rom_HRDATA             (rom_HRDATA),
    .rom_HREADYOUT          (rom_HREADYOUT),
    .rom_HRESP              (rom_HRESP),

    .ram_HADDR              (ram_HADDR),
    .ram_HBURST             (ram_HBURST),
    .ram_HMASTLOCK          (ram_HMASTLOCK),
    .ram_HPROT              (ram_HPROT),
    .ram_HSIZE              (ram_HSIZE),
    .ram_HTRANS             (ram_HTRANS),
    .ram_HWDATA             (ram_HWDATA),
    .ram_HWRITE             (ram_HWRITE),
    .ram_HREADYIN           (ram_HREADYIN),
    .ram_HSEL               (ram_HSEL),
    .ram_HRDATA             (ram_HRDATA),
    .ram_HREADYOUT          (ram_HREADYOUT),
    .ram_HRESP              (ram_HRESP),

    .uart_HADDR             (uart_HADDR),
    .uart_HBURST            (uart_HBURST),
    .uart_HMASTLOCK         (uart_HMASTLOCK),
    .uart_HPROT             (uart_HPROT),
    .uart_HSIZE             (uart_HSIZE),
    .uart_HTRANS            (uart_HTRANS),
    .uart_HWDATA            (uart_HWDATA),
    .uart_HWRITE            (uart_HWRITE),
    .uart_HREADYIN          (uart_HREADYIN),
    .uart_HSEL              (uart_HSEL),
    .uart_HRDATA            (uart_HRDATA),
    .uart_HREADYOUT         (uart_HREADYOUT),
    .uart_HRESP             (uart_HRESP),

    .gpio_ctrl_HADDR        (gpio_ctrl_HADDR),
    .gpio_ctrl_HBURST       (gpio_ctrl_HBURST),
    .gpio_ctrl_HMASTLOCK    (gpio_ctrl_HMASTLOCK),
    .gpio_ctrl_HPROT        (gpio_ctrl_HPROT),
    .gpio_ctrl_HSIZE        (gpio_ctrl_HSIZE),
    .gpio_ctrl_HTRANS       (gpio_ctrl_HTRANS),
    .gpio_ctrl_HWDATA       (gpio_ctrl_HWDATA),
    .gpio_ctrl_HWRITE       (gpio_ctrl_HWRITE),
    .gpio_ctrl_HREADYIN     (gpio_ctrl_HREADYIN),
    .gpio_ctrl_HSEL         (gpio_ctrl_HSEL),
    .gpio_ctrl_HRDATA       (gpio_ctrl_HRDATA),
    .gpio_ctrl_HREADYOUT    (gpio_ctrl_HREADYOUT),
    .gpio_ctrl_HRESP        (gpio_ctrl_HRESP),

    .qpsi_HADDR             (qpsi_HADDR),
    .qpsi_HBURST            (qpsi_HBURST),
    .qpsi_HMASTLOCK         (qpsi_HMASTLOCK),
    .qpsi_HPROT             (qpsi_HPROT),
    .qpsi_HSIZE             (qpsi_HSIZE),
    .qpsi_HTRANS            (qpsi_HTRANS),
    .qpsi_HWDATA            (qpsi_HWDATA),
    .qpsi_HWRITE            (qpsi_HWRITE),
    .qpsi_HREADYIN          (qpsi_HREADYIN),
    .qpsi_HSEL              (qpsi_HSEL),
    .qpsi_HRDATA            (qpsi_HRDATA),
    .qpsi_HREADYOUT         (qpsi_HREADYOUT),
    .qpsi_HRESP             (qpsi_HRESP),

    .spi_m_HADDR            (spi_m_HADDR),
    .spi_m_HBURST           (spi_m_HBURST),
    .spi_m_HMASTLOCK        (spi_m_HMASTLOCK),
    .spi_m_HPROT            (spi_m_HPROT),
    .spi_m_HSIZE            (spi_m_HSIZE),
    .spi_m_HTRANS           (spi_m_HTRANS),
    .spi_m_HWDATA           (spi_m_HWDATA),
    .spi_m_HWRITE           (spi_m_HWRITE),
    .spi_m_HREADYIN         (spi_m_HREADYIN),
    .spi_m_HSEL             (spi_m_HSEL),
    .spi_m_HRDATA           (spi_m_HRDATA),
    .spi_m_HREADYOUT        (spi_m_HREADYOUT),
    .spi_m_HRESP            (spi_m_HRESP),

    .spi_s_HADDR            (spi_s_HADDR),
    .spi_s_HBURST           (spi_s_HBURST),
    .spi_s_HMASTLOCK        (spi_s_HMASTLOCK),
    .spi_s_HPROT            (spi_s_HPROT),
    .spi_s_HSIZE            (spi_s_HSIZE),
    .spi_s_HTRANS           (spi_s_HTRANS),
    .spi_s_HWDATA           (spi_s_HWDATA),
    .spi_s_HWRITE           (spi_s_HWRITE),
    .spi_s_HREADYIN         (spi_s_HREADYIN),
    .spi_s_HSEL             (spi_s_HSEL),
    .spi_s_HRDATA           (spi_s_HRDATA),
    .spi_s_HREADYOUT        (spi_s_HREADYOUT),
    .spi_s_HRESP            (spi_s_HRESP),

    .ext_periph_HADDR       (ext_periph_HADDR),
    .ext_periph_HBURST      (ext_periph_HBURST),
    .ext_periph_HMASTLOCK   (ext_periph_HMASTLOCK),
    .ext_periph_HPROT       (ext_periph_HPROT),
    .ext_periph_HSIZE       (ext_periph_HSIZE),
    .ext_periph_HTRANS      (ext_periph_HTRANS),
    .ext_periph_HWDATA      (ext_periph_HWDATA),
    .ext_periph_HWRITE      (ext_periph_HWRITE),
    .ext_periph_HREADYIN    (ext_periph_HREADYIN),
    .ext_periph_HSEL        (ext_periph_HSEL),
    .ext_periph_HRDATA      (ext_periph_HRDATA),
    .ext_periph_HREADYOUT   (ext_periph_HREADYOUT),
    .ext_periph_HRESP       (ext_periph_HRESP)

  `ifdef DEBUG_PERIPH
    ,
    .debug_HADDR            (debug_HADDR),
    .debug_HBURST           (debug_HBURST),
    .debug_HMASTLOCK        (debug_HMASTLOCK),
    .debug_HPROT            (debug_HPROT),
    .debug_HSIZE            (debug_HSIZE),
    .debug_HTRANS           (debug_HTRANS),
    .debug_HWDATA           (debug_HWDATA),
    .debug_HWRITE           (debug_HWRITE),
    .debug_HREADYIN         (debug_HREADYIN),
    .debug_HSEL             (debug_HSEL),
    .debug_HRDATA           (debug_HRDATA),
    .debug_HREADYOUT        (debug_HREADYOUT),
    .debug_HRESP            (debug_HRESP)
  `endif
  );

//--- ROM ------------------------------------------------------------------------------

  ahb_rom #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_rom (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (rom_HADDR),
    .HBURST       (rom_HBURST),
    .HMASTLOCK    (rom_HMASTLOCK),
    .HPROT        (rom_HPROT),
    .HSIZE        (rom_HSIZE),
    .HTRANS       (rom_HTRANS),
    .HWDATA       (rom_HWDATA),
    .HWRITE       (rom_HWRITE),
    .HRDATA       (rom_HRDATA),
    .HREADYOUT    (rom_HREADYOUT),
    .HRESP        (rom_HRESP),
    .HREADYIN     (rom_HREADYIN),
    .HSEL         (rom_HSEL)
  );

  //--- RAM ------------------------------------------------------------------------------

  ahb_ram #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_ram (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (ram_HADDR),
    .HBURST       (ram_HBURST),
    .HMASTLOCK    (ram_HMASTLOCK),
    .HPROT        (ram_HPROT),
    .HSIZE        (ram_HSIZE),
    .HTRANS       (ram_HTRANS),
    .HWDATA       (ram_HWDATA),
    .HWRITE       (ram_HWRITE),
    .HRDATA       (ram_HRDATA),
    .HREADYOUT    (ram_HREADYOUT),
    .HRESP        (ram_HRESP),
    .HREADYIN     (ram_HREADYIN),
    .HSEL         (ram_HSEL)
  );

  //--- UART ------------------------------------------------------------------------------

  ahb_uart #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_uart (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (uart_HADDR),
    .HBURST       (uart_HBURST),
    .HMASTLOCK    (uart_HMASTLOCK),
    .HPROT        (uart_HPROT),
    .HSIZE        (uart_HSIZE),
    .HTRANS       (uart_HTRANS),
    .HWDATA       (uart_HWDATA),
    .HWRITE       (uart_HWRITE),
    .HRDATA       (uart_HRDATA),
    .HREADYOUT    (uart_HREADYOUT),
    .HRESP        (uart_HRESP),
    .HREADYIN     (uart_HREADYIN),
    .HSEL         (uart_HSEL),

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
    .HADDR        (qpsi_HADDR),
    .HBURST       (qpsi_HBURST),
    .HMASTLOCK    (qpsi_HMASTLOCK),
    .HPROT        (qpsi_HPROT),
    .HSIZE        (qpsi_HSIZE),
    .HTRANS       (qpsi_HTRANS),
    .HWDATA       (qpsi_HWDATA),
    .HWRITE       (qpsi_HWRITE),
    .HRDATA       (qpsi_HRDATA),
    .HREADYOUT    (qpsi_HREADYOUT),
    .HRESP        (qpsi_HRESP),
    .HREADYIN     (qpsi_HREADYIN),
    .HSEL         (qpsi_HSEL)
  );

  //--- SPI Master ------------------------------------------------------------------------
  
  // FIXME - replace with actual SPI Master peripheral
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_spi_m_stub (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (spi_m_HADDR),
    .HBURST       (spi_m_HBURST),
    .HMASTLOCK    (spi_m_HMASTLOCK),
    .HPROT        (spi_m_HPROT),
    .HSIZE        (spi_m_HSIZE),
    .HTRANS       (spi_m_HTRANS),
    .HWDATA       (spi_m_HWDATA),
    .HWRITE       (spi_m_HWRITE),
    .HRDATA       (spi_m_HRDATA),
    .HREADYOUT    (spi_m_HREADYOUT),
    .HRESP        (spi_m_HRESP),
    .HREADYIN     (spi_m_HREADYIN),
    .HSEL         (spi_m_HSEL)
  );

  //--- SPI Slave -------------------------------------------------------------------------

`ifdef DRY_RUN

  // The SPI slave is out of scope for the dry run - occupy its fabric slot
  // with the same placeholder the not-yet-implemented peripherals use, so the
  // interconnect still sees eight slaves.
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_spi_s_stub (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),
    .HADDR        (spi_s_HADDR),
    .HBURST       (spi_s_HBURST),
    .HMASTLOCK    (spi_s_HMASTLOCK),
    .HPROT        (spi_s_HPROT),
    .HSIZE        (spi_s_HSIZE),
    .HTRANS       (spi_s_HTRANS),
    .HWDATA       (spi_s_HWDATA),
    .HWRITE       (spi_s_HWRITE),
    .HRDATA       (spi_s_HRDATA),
    .HREADYOUT    (spi_s_HREADYOUT),
    .HRESP        (spi_s_HRESP),
    .HREADYIN     (spi_s_HREADYIN),
    .HSEL         (spi_s_HSEL)
  );

  // io_ss still drives mux_spi_s_{ss,sck,mosi}_i towards the (absent) slave;
  // with no consumer those three pad-input paths fall out in synthesis.
  assign mux_spi_s_miso_o = 1'b0;

`else

  ahb_spi_s #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_spi_s (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),

    .HADDR        (spi_s_HADDR),
    .HBURST       (spi_s_HBURST),
    .HMASTLOCK    (spi_s_HMASTLOCK),
    .HPROT        (spi_s_HPROT),
    .HSIZE        (spi_s_HSIZE),
    .HTRANS       (spi_s_HTRANS),
    .HWDATA       (spi_s_HWDATA),
    .HWRITE       (spi_s_HWRITE),
    .HRDATA       (spi_s_HRDATA),
    .HREADYOUT    (spi_s_HREADYOUT),
    .HRESP        (spi_s_HRESP),
    .HREADYIN     (spi_s_HREADYIN),
    .HSEL         (spi_s_HSEL),

    // TODO - add IRQs

    .spi_ss       (mux_spi_s_ss_i),
    .spi_sck      (mux_spi_s_sck_i),
    .spi_mosi     (mux_spi_s_mosi_i),
    .spi_miso     (mux_spi_s_miso_o)
  );

`endif

  //--- Input/Output Subsystem (GPIO MUX) -----------------------------------------------------------------

  io_ss #(
    .ADDR_WIDTH      (ADDR_WIDTH),
    .DATA_WIDTH      (DATA_WIDTH),
    .NUM_GPIO        (NUM_GPIO)

  ) u_io_ss (
    .HCLK            (HCLK),
    .HRESETn         (HRESETn),

    .HADDR           (gpio_ctrl_HADDR),
    .HBURST          (gpio_ctrl_HBURST),
    .HMASTLOCK       (gpio_ctrl_HMASTLOCK),
    .HPROT           (gpio_ctrl_HPROT),
    .HSIZE           (gpio_ctrl_HSIZE),
    .HTRANS          (gpio_ctrl_HTRANS),
    .HWDATA          (gpio_ctrl_HWDATA),
    .HWRITE          (gpio_ctrl_HWRITE),
    .HRDATA          (gpio_ctrl_HRDATA),
    .HREADYOUT       (gpio_ctrl_HREADYOUT),
    .HRESP           (gpio_ctrl_HRESP),
    .HREADYIN        (gpio_ctrl_HREADYIN),
    .HSEL            (gpio_ctrl_HSEL),

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

  assign ext_HADDR     = ext_periph_HADDR;
  assign ext_HBURST    = ext_periph_HBURST;
  assign ext_HMASTLOCK = ext_periph_HMASTLOCK;
  assign ext_HPROT     = ext_periph_HPROT;
  assign ext_HSIZE     = ext_periph_HSIZE;
  assign ext_HTRANS    = ext_periph_HTRANS;
  assign ext_HWDATA    = ext_periph_HWDATA;
  assign ext_HWRITE    = ext_periph_HWRITE;
  assign ext_periph_HRDATA    = ext_HRDATA;
  assign ext_periph_HREADYOUT = ext_HREADY;
  assign ext_periph_HRESP     = ext_HRESP;

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
    .HADDR        (debug_HADDR),
    .HBURST       (debug_HBURST),
    .HMASTLOCK    (debug_HMASTLOCK),
    .HPROT        (debug_HPROT),
    .HSIZE        (debug_HSIZE),
    .HTRANS       (debug_HTRANS),
    .HWDATA       (debug_HWDATA),
    .HWRITE       (debug_HWRITE),
    .HRDATA       (debug_HRDATA),
    .HREADYOUT    (debug_HREADYOUT),
    .HRESP        (debug_HRESP),
    .HREADYIN     (debug_HREADYIN),
    .HSEL         (debug_HSEL),

    .trace_valid  (trace_valid),
    .trace_data   (trace_data)
  );
`endif

endmodule
