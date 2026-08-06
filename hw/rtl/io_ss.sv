// IO subsystem
//
// Sits between the serial peripherals (SPI S/M, QSPI) and the GPIO pads, and
// owns the GPIO mux CSRs. The serial port names keep the *pad* direction
// suffix (`_i` = chip input pin, `_o` = chip output pin), so relative to this
// module a pad input is an output port (it is driven towards the peripheral)
// and a pad output is an input port.
//
// Specification: planning/Hardware/design/blocks/GPIO Mux.md

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

  //--- Pin assignment -------------------------------------------------------
  //
  // The only place in the design where a pad is tied to a peripheral. The mux
  // below is written against the generic mux_n_* buses and names nothing.
  // Pad 15 has no alternate function - it is the spare.

  localparam int PIN_SPI_S_SS    = 0;
  localparam int PIN_SPI_S_SCK   = 1;
  localparam int PIN_SPI_S_MOSI  = 2;
  localparam int PIN_SPI_S_MISO  = 3;
  localparam int PIN_SPI_M_SS    = 4;
  localparam int PIN_SPI_M_SCK   = 5;
  localparam int PIN_SPI_M_MOSI  = 6;
  localparam int PIN_SPI_M_MISO  = 7;
  localparam int PIN_QSPI_SCK    = 8;
  localparam int PIN_QSPI_CE_N0  = 9;
  localparam int PIN_QSPI_CE_N1  = 10;
  localparam int PIN_QSPI_SIO0   = 11;
  localparam int PIN_QSPI_SIO1   = 12;
  localparam int PIN_QSPI_SIO2   = 13;
  localparam int PIN_QSPI_SIO3   = 14;

  // NUM_GPIO is exposed up through periph_ss and digital_ss, but the table
  // above is fixed for 16 pads. Fail loudly rather than silently mis-routing.
  initial begin : check_num_gpio
    if (NUM_GPIO != 16)
      $error("%m: NUM_GPIO must be 16 - the pin assignment table is not parameterised");
  end

  //--- CSR values from the GPIO control block -------------------------------

  logic [NUM_GPIO-1:0] gpio_out_val;   // GPIO_OUT
  logic [NUM_GPIO-1:0] gpio_oe_val;    // GPIO_OE
  logic [NUM_GPIO-1:0] alt_sel;        // GPIO_ALTSEL

  //--- Generic per-pad mux buses --------------------------------------------
  //
  // mux_n_o / mux_n_oe carry what the alternate function drives towards the
  // pad; mux_n_i carries the pad value back to the alternate function.

  logic [NUM_GPIO-1:0] mux_n_o;
  logic [NUM_GPIO-1:0] mux_n_oe;
  logic [NUM_GPIO-1:0] mux_n_i;

  //--- GPIO Control Peripheral --------------------------------------------------

  ahb_gpio_ctrl #(
    .ADDR_WIDTH     (ADDR_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .NUM_GPIO       (NUM_GPIO)
  ) u_gpio_ctrl (
    .HCLK           (HCLK),
    .HRESETn        (HRESETn),

    .HADDR          (HADDR),
    .HBURST         (HBURST),
    .HMASTLOCK      (HMASTLOCK),
    .HPROT          (HPROT),
    .HSIZE          (HSIZE),
    .HTRANS         (HTRANS),
    .HWDATA         (HWDATA),
    .HWRITE         (HWRITE),

    .HRDATA         (HRDATA),
    .HREADYOUT      (HREADYOUT),
    .HRESP          (HRESP),

    .HREADYIN       (HREADYIN),
    .HSEL           (HSEL),

    .mux_io_i       (gpio_in),
    .mux_io_o       (gpio_out_val),
    .mux_alt_sel    (alt_sel),

    // NOTE: gpio_oe comes out of the register block as the raw GPIO_OE value
    // and is muxed below, not passed straight to the pad. The QSPI data pads
    // are bidirectional and turn around inside a transaction, so their output
    // enable has to come from qspi_sio_oe when the pad is in alternate mode -
    // firmware cannot drive GPIO_OE fast enough to do it.
    .gpio_oe        (gpio_oe_val),

    // Pad electricals pass straight through to the pads.
    .gpio_sync_en_n (gpio_sync_en_n),
    .gpio_ie        (gpio_ie),
    .gpio_pu        (gpio_pu),
    .gpio_pd        (gpio_pd),
    .gpio_cs        (gpio_cs),
    .gpio_sl        (gpio_sl)
  );

  //--- Alternate function -> pad --------------------------------------------
  //
  // Marshal the serial outputs onto the generic per-pad buses. Pads whose
  // alternate function is an input, and pad 15 which has none, contribute 0
  // and hold their output enable low - the mux below still selects them when
  // ALTSEL says so, which correctly parks the pad as an input.

  always_comb begin
    mux_n_o  = '0;
    mux_n_oe = '0;

    // SPI slave: three pad inputs, one output.
    mux_n_o [PIN_SPI_S_MISO] = spi_s_miso_o;
    mux_n_oe[PIN_SPI_S_MISO] = 1'b1;

    // SPI master: three pad outputs, one input.
    mux_n_o [PIN_SPI_M_SS]   = spi_m_ss_o;
    mux_n_oe[PIN_SPI_M_SS]   = 1'b1;
    mux_n_o [PIN_SPI_M_SCK]  = spi_m_sck_o;
    mux_n_oe[PIN_SPI_M_SCK]  = 1'b1;
    mux_n_o [PIN_SPI_M_MOSI] = spi_m_mosi_o;
    mux_n_oe[PIN_SPI_M_MOSI] = 1'b1;

    // QSPI: clock and chip selects are always driven; the four data pads are
    // bidirectional and turn around within a transaction, so their enable
    // comes from the peripheral rather than from a register.
    mux_n_o [PIN_QSPI_SCK]   = qspi_sck_o;
    mux_n_oe[PIN_QSPI_SCK]   = 1'b1;
    mux_n_o [PIN_QSPI_CE_N0] = qspi_ce_n_o[0];
    mux_n_oe[PIN_QSPI_CE_N0] = 1'b1;
    mux_n_o [PIN_QSPI_CE_N1] = qspi_ce_n_o[1];
    mux_n_oe[PIN_QSPI_CE_N1] = 1'b1;

    mux_n_o [PIN_QSPI_SIO0]  = qspi_sio_o [0];
    mux_n_oe[PIN_QSPI_SIO0]  = qspi_sio_oe[0];
    mux_n_o [PIN_QSPI_SIO1]  = qspi_sio_o [1];
    mux_n_oe[PIN_QSPI_SIO1]  = qspi_sio_oe[1];
    mux_n_o [PIN_QSPI_SIO2]  = qspi_sio_o [2];
    mux_n_oe[PIN_QSPI_SIO2]  = qspi_sio_oe[2];
    mux_n_o [PIN_QSPI_SIO3]  = qspi_sio_o [3];
    mux_n_oe[PIN_QSPI_SIO3]  = qspi_sio_oe[3];
  end

  //--- The mux --------------------------------------------------------------
  //
  // Purely combinational: a pad in alternate-function mode adds no cycles
  // between the peripheral and the pin (GRPR-GPIO-015).

  assign gpio_out = (mux_n_o  & alt_sel) | (gpio_out_val & ~alt_sel);
  assign gpio_oe  = (mux_n_oe & alt_sel) | (gpio_oe_val  & ~alt_sel);

  //--- Pad -> alternate function --------------------------------------------
  //
  // Gated by alt_sel so a pad left in GPIO mode cannot drive a peripheral
  // input - without this, toggling a GPIO would clock the SPI slave.

  assign mux_n_i = gpio_in & alt_sel;

  // The AND above idles every unselected input at 0, which is the right idle
  // for all of these except spi_s_ss: it is active low, so an idle of 0 would
  // read as "selected" and the SPI slave would respond to a bus it does not
  // own. Force it high when its pad is not assigned to the SPI slave.
  assign spi_s_ss_i   = alt_sel[PIN_SPI_S_SS] ? mux_n_i[PIN_SPI_S_SS] : 1'b1;
  assign spi_s_sck_i  = mux_n_i[PIN_SPI_S_SCK];
  assign spi_s_mosi_i = mux_n_i[PIN_SPI_S_MOSI];

  assign spi_m_miso_i = mux_n_i[PIN_SPI_M_MISO];

  assign qspi_sio_i   = {
    mux_n_i[PIN_QSPI_SIO3],
    mux_n_i[PIN_QSPI_SIO2],
    mux_n_i[PIN_QSPI_SIO1],
    mux_n_i[PIN_QSPI_SIO0]
  };

endmodule
