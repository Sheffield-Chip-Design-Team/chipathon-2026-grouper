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

  // Now wired to ahb_qspi
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

  // FIXME - slot wired to a sized, pad-connected ahb_stub_slave, not ahb_spi_m
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

  // Only the low EXT_*_WIDTH bits of HADDR/HWDATA leave the block, and HSEL
  // and HREADYIN have no external port at all - see the external peripheral
  // section at the bottom of this file.
  /* verilator lint_off UNUSEDSIGNAL */
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
  /* verilator lint_on UNUSEDSIGNAL */
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

logic       mux_qspi_sck_o;
logic [1:0] mux_qspi_ce_n_o;
logic [3:0] mux_qspi_sio_i;
logic [3:0] mux_qspi_sio_o;
logic [3:0] mux_qspi_sio_oe;

//--- Interconnect ----------------------------------------------------------------------

  interconnect_ss #(
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
    // ROM and RAM are not fabric slots: cpu_ss reaches them over its own
    // native memory ports and never puts their addresses on HADDR.
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

  ahb_qspi #(
    .ADDR_WIDTH (12),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_qspi (
    .HCLK         (HCLK),
    .HRESETn      (HRESETn),

    .HADDR        (qpsi_HADDR[11:0]),
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
    .HSEL         (qpsi_HSEL),

    .qspi_sck_o   (mux_qspi_sck_o),
    .qspi_ce_n_o  (mux_qspi_ce_n_o),
    .qspi_sio_i   (mux_qspi_sio_i),
    .qspi_sio_o   (mux_qspi_sio_o),
    .qspi_sio_oe  (mux_qspi_sio_oe),

    .irq          ()
  );

  //--- SPI Master ------------------------------------------------------------------------
  
  // FIXME - replace with hw/rtl/spi_m/ahb_spi_m.sv, whose pad ports are named
  // SPI_MOSI/SPI_SCK/SPI_CS_N/SPI_MISO and will need mapping onto the io_ss
  // names below. Until then the stub holds the slot at a representative size:
  // 1706 GE, from `make measure-ge` (ahb_spi_m synthesizes to 14,402.7 um^2 =
  // 1312 GE) x1.3 for the one remaining open item (GRPR-SPIM-005). That lands
  // inside GRPR-SPIM-015's 1,500-2,000 GE estimate, which the spec flagged as
  // unconfirmed by synthesis - it is now confirmed. See
  // librelane/classic/TRIAL_NOTES.md.
  
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .TARGET_GE  (1706),
    .PAD_OUT_W  (3),
    .PAD_IN_W   (1)
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
    .HSEL         (spi_m_HSEL),

    // io_ss drives these pads' output enables high itself, so pad_oe is unused.
    .pad_in       (mux_spi_m_miso_i),
    .pad_out      ({mux_spi_m_mosi_o, mux_spi_m_sck_o, mux_spi_m_ss_o}),
    .pad_oe       ()
  );

  //--- SPI Slave -------------------------------------------------------------------------

`ifdef DRY_RUN

  // The SPI slave is out of scope for the dry run - occupy its fabric slot
  // with the same placeholder the not-yet-implemented peripherals use, so the
  // interconnect still sees eight slaves.
  //
  // Sized at 635 GE, from `make measure-ge` (ahb_spi_s synthesizes to 3,483.8
  // um^2 = 317 GE) x2.0 for what it still has to grow (two-cycle error
  // response, IRQs, and the FIFOs that GRPR-SPIS-012's 1.25 MB/s firmware load
  // needs). See librelane/classic/TRIAL_NOTES.md.
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .TARGET_GE  (635),
    .PAD_OUT_W  (1),
    .PAD_IN_W   (3)
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
    .HSEL         (spi_s_HSEL),

    // Same pad signals the real ahb_spi_s takes below, so the SPI slave's four
    // pad paths through io_ss exist in the netlist either way. spi_sck arrives
    // here as plain data into an HCLK-clocked register, so the stub adds no
    // clock domain of its own. io_ss drives this pad's output enable high
    // itself, so pad_oe is unused.
    .pad_in       ({mux_spi_s_mosi_i, mux_spi_s_sck_i, mux_spi_s_ss_i}),
    .pad_out      (mux_spi_s_miso_o),
    .pad_oe       ()
  );

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

    // FIXME - tied off until the SPI master is implemented
    .spi_m_sck_o     (1'b0),
    .spi_m_mosi_o    (1'b0),
    .spi_m_miso_i    (),
    .spi_m_ss_o      (1'b1),

    .qspi_sck_o       (mux_qspi_sck_o),
    .qspi_ce_n_o      (mux_qspi_ce_n_o),
    .qspi_sio_i       (mux_qspi_sio_i),
    .qspi_sio_o       (mux_qspi_sio_o),
    .qspi_sio_oe      (mux_qspi_sio_oe),

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
  
  // FIXME - bridge this to an external interface
  //
  // The external port is deliberately narrower than the fabric slot
  // (EXT_ADDR_WIDTH / EXT_DATA_WIDTH, both 8 by default) to keep the wire
  // count out of the block down, so the address and write data are truncated
  // and the read data zero-extended. Note the consequence: the slot decodes a
  // 64 KiB window but an 8-bit address only reaches its first 256 bytes.
  //
  // ext_periph_HSEL and ext_periph_HREADYIN have nowhere to go until the
  // bridge above exists - an external slave cannot tell it is selected
  // without them.

  assign ext_HADDR     = ext_periph_HADDR[EXT_ADDR_WIDTH-1:0];
  assign ext_HBURST    = ext_periph_HBURST;
  assign ext_HMASTLOCK = ext_periph_HMASTLOCK;
  assign ext_HPROT     = ext_periph_HPROT;
  assign ext_HSIZE     = ext_periph_HSIZE;
  assign ext_HTRANS    = ext_periph_HTRANS;
  assign ext_HWDATA    = ext_periph_HWDATA[EXT_DATA_WIDTH-1:0];
  assign ext_HWRITE    = ext_periph_HWRITE;
  assign ext_periph_HRDATA    = {{(DATA_WIDTH-EXT_DATA_WIDTH){1'b0}}, ext_HRDATA};
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
