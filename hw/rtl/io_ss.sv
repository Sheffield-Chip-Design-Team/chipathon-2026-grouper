// IO subsystem
//
// Sits between the serial peripherals (SPI S/M, QSPI) and the GPIO pads, and
// owns the GPIO mux CSRs. The serial port names keep the *pad* direction
// suffix (`_i` = chip input pin, `_o` = chip output pin), so relative to this
// module a pad input is an output port (it is driven towards the peripheral)
// and a pad output is an input port.

module io_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int NUM_GPIO   = 16
) (
  input logic                    HCLK,
  input logic                    HRESETn,

  // AHB Slave Interface (From Interconnect)
  input logic [ADDR_WIDTH-1:0]   HADDR,
  input logic [2:0]              HBURST,
  input logic                    HMASTLOCK,
  input logic [3:0]              HPROT,
  input logic [2:0]              HSIZE,
  input logic [1:0]              HTRANS,
  input logic [DATA_WIDTH-1:0]   HWDATA,
  input logic                    HWRITE,

  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  input logic                   HREADYIN,
  input logic                   HSEL,

  // Serial Interface Signals 

  // SPI Slave interface
  output logic                   spi_s_ss_i,
  output logic                   spi_s_sck_i,
  output logic                   spi_s_mosi_i,
  input  logic                   spi_s_miso_o,

  // SPI Master interface
  input  logic                   spi_m_sck_o,
  input  logic                   spi_m_mosi_o,
  output logic                   spi_m_miso_i,
  input  logic                   spi_m_ss_o,

  // QSPI interface
  input  logic                   qspi_sck_o,
  input  logic [1:0]             qspi_ce_n_o,
  output logic [3:0]             qspi_sio_i,
  input  logic [3:0]             qspi_sio_o,
  input  logic [3:0]             qspi_sio_oe,

  // GPIO pin control interface
  input  wire [NUM_GPIO-1:0]     gpio_in,
  output wire [NUM_GPIO-1:0]     gpio_out,
  output wire [NUM_GPIO-1:0]     gpio_oe,
  output wire [NUM_GPIO-1:0]     gpio_cs,
  output wire [NUM_GPIO-1:0]     gpio_sl,
  output wire [NUM_GPIO-1:0]     gpio_ie,
  output wire [NUM_GPIO-1:0]     gpio_pu,
  output wire [NUM_GPIO-1:0]     gpio_pd,

  output wire [NUM_GPIO-1:0]     gpio_sync_en_n

);

  //--- GPIO MUX Peripheral --------------------------------------------------------------

  // FIXME - replace with actual GPIO peripheral
  ahb_stub_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH)
  ) u_gpio_ctrl (

    .HCLK         (HCLK),
    .HRESETn      (HRESETn),

    .HADDR        (HADDR),
    .HBURST       (HBURST),
    .HMASTLOCK    (HMASTLOCK),
    .HPROT        (HPROT),
    .HSIZE        (HSIZE),
    .HTRANS       (HTRANS),
    .HWDATA       (HWDATA),
    .HWRITE       (HWRITE),

    .HRDATA       (HRDATA),
    .HREADYOUT    (HREADYOUT),

    .HRESP        (HRESP),
    .HREADYIN     (HREADYIN),
    .HSEL         (HSEL)
  );

  //--- Pad mux tie-offs -----------------------------------------------------------------

  // FIXME - the mux itself is not implemented yet. Hold everything it would
  // drive at a safe idle so no peripheral or pad sees X: the SPI slave stays
  // deselected, the QSPI/SPI master inputs read 0, and every pad is an
  // un-driven, un-pulled input with the synchronisers enabled.
  assign spi_s_ss_i   = 1'b1;   // active low chip select - deselected
  assign spi_s_sck_i  = 1'b0;
  assign spi_s_mosi_i = 1'b0;
  assign spi_m_miso_i = 1'b0;
  assign qspi_sio_i   = '0;

  assign gpio_out        = '0;
  assign gpio_oe         = '0;
  assign gpio_cs         = '0;
  assign gpio_sl         = '0;
  assign gpio_ie         = '0;
  assign gpio_pu         = '0;
  assign gpio_pd         = '0;
  assign gpio_sync_en_n  = '0;  // 0 = synchronised

endmodule
