// AHB-Lite interconnect subsystem
//
// Single master (the CPU) fanned out to NUM_SLAVES slaves: address decode,
// request fan-out, and a registered response mux.
//
// Peripheral ports are flat AHB signal groups, NOT `ahb3lite_intf` modports.
// This is the same rule cpu_ss.sv states, and it is load-bearing: a Verilog
// netlist has no representation for an interface port, so a synthesis
// frontend that preserves module boundaries (yosys-slang with
// --keep-hierarchy, for one) cannot wire one up. When that happens the
// fabric's connections silently vanish, every peripheral output becomes
// undriven, and the whole SoC constant-folds away to tie cells. Keep every
// hierarchy boundary in this design flat.
//
// `ahb3lite_intf` remains available for testbenches, where full elaboration
// makes it safe and useful.

module interconnect_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter logic [ADDR_WIDTH-1:0] QSPI_MEM_BASE = 32'h8002_0000,
`ifdef DEBUG_PERIPH
  localparam int NUM_SLAVES = 7
`else
  localparam int NUM_SLAVES = 6
`endif
)(
  // Clock and Reset
  input logic                    HCLK,
  input logic                    HRESETn,

  // AHBlite Slave Interface (CPU)
  input logic [ADDR_WIDTH-1:0]   HADDR,
  input logic [2:0]              HBURST,
  input logic                    HMASTLOCK,
  input logic [3:0]              HPROT,
  input logic [2:0]              HSIZE,
  input logic [1:0]              HTRANS,
  input logic [DATA_WIDTH-1:0]   HWDATA,
  input logic                    HWRITE,
  output logic [DATA_WIDTH-1:0]  HRDATA,
  output logic                   HREADY,
  output logic                   HRESP,

  // --- Peripheral master ports ---------------------------------------------
  // One flat AHB group per slave, in slot order. The interconnect is the
  // master on all of them.

  // UART (slot 0)
  output logic [ADDR_WIDTH-1:0]  uart_HADDR,
  output logic [2:0]             uart_HBURST,
  output logic                   uart_HMASTLOCK,
  output logic [3:0]             uart_HPROT,
  output logic [2:0]             uart_HSIZE,
  output logic [1:0]             uart_HTRANS,
  output logic [DATA_WIDTH-1:0]  uart_HWDATA,
  output logic                   uart_HWRITE,
  output logic                   uart_HREADYIN,
  output logic                   uart_HSEL,
  input  logic [DATA_WIDTH-1:0]  uart_HRDATA,
  input  logic                   uart_HREADYOUT,
  input  logic                   uart_HRESP,

  // GPIO controller / IO subsystem (slot 1)
  output logic [ADDR_WIDTH-1:0]  gpio_ctrl_HADDR,
  output logic [2:0]             gpio_ctrl_HBURST,
  output logic                   gpio_ctrl_HMASTLOCK,
  output logic [3:0]             gpio_ctrl_HPROT,
  output logic [2:0]             gpio_ctrl_HSIZE,
  output logic [1:0]             gpio_ctrl_HTRANS,
  output logic [DATA_WIDTH-1:0]  gpio_ctrl_HWDATA,
  output logic                   gpio_ctrl_HWRITE,
  output logic                   gpio_ctrl_HREADYIN,
  output logic                   gpio_ctrl_HSEL,
  input  logic [DATA_WIDTH-1:0]  gpio_ctrl_HRDATA,
  input  logic                   gpio_ctrl_HREADYOUT,
  input  logic                   gpio_ctrl_HRESP,

  // QSPI (slot 2)
  output logic [ADDR_WIDTH-1:0]  qpsi_HADDR,
  output logic [2:0]             qpsi_HBURST,
  output logic                   qpsi_HMASTLOCK,
  output logic [3:0]             qpsi_HPROT,
  output logic [2:0]             qpsi_HSIZE,
  output logic [1:0]             qpsi_HTRANS,
  output logic [DATA_WIDTH-1:0]  qpsi_HWDATA,
  output logic                   qpsi_HWRITE,
  output logic                   qpsi_HREADYIN,
  output logic                   qpsi_HSEL,
  output logic                   qpsi_HMEMSEL,
  output logic [22:0]            qpsi_HMEMADDR,
  input  logic [DATA_WIDTH-1:0]  qpsi_HRDATA,
  input  logic                   qpsi_HREADYOUT,
  input  logic                   qpsi_HRESP,

  // SPI master (slot 3)
  output logic [ADDR_WIDTH-1:0]  spi_m_HADDR,
  output logic [2:0]             spi_m_HBURST,
  output logic                   spi_m_HMASTLOCK,
  output logic [3:0]             spi_m_HPROT,
  output logic [2:0]             spi_m_HSIZE,
  output logic [1:0]             spi_m_HTRANS,
  output logic [DATA_WIDTH-1:0]  spi_m_HWDATA,
  output logic                   spi_m_HWRITE,
  output logic                   spi_m_HREADYIN,
  output logic                   spi_m_HSEL,
  input  logic [DATA_WIDTH-1:0]  spi_m_HRDATA,
  input  logic                   spi_m_HREADYOUT,
  input  logic                   spi_m_HRESP,

  // SPI slave (slot 4)
  output logic [ADDR_WIDTH-1:0]  spi_s_HADDR,
  output logic [2:0]             spi_s_HBURST,
  output logic                   spi_s_HMASTLOCK,
  output logic [3:0]             spi_s_HPROT,
  output logic [2:0]             spi_s_HSIZE,
  output logic [1:0]             spi_s_HTRANS,
  output logic [DATA_WIDTH-1:0]  spi_s_HWDATA,
  output logic                   spi_s_HWRITE,
  output logic                   spi_s_HREADYIN,
  output logic                   spi_s_HSEL,
  input  logic [DATA_WIDTH-1:0]  spi_s_HRDATA,
  input  logic                   spi_s_HREADYOUT,
  input  logic                   spi_s_HRESP,

  // External peripheral window (slot 5)
  output logic [ADDR_WIDTH-1:0]  ext_periph_HADDR,
  output logic [2:0]             ext_periph_HBURST,
  output logic                   ext_periph_HMASTLOCK,
  output logic [3:0]             ext_periph_HPROT,
  output logic [2:0]             ext_periph_HSIZE,
  output logic [1:0]             ext_periph_HTRANS,
  output logic [DATA_WIDTH-1:0]  ext_periph_HWDATA,
  output logic                   ext_periph_HWRITE,
  output logic                   ext_periph_HREADYIN,
  output logic                   ext_periph_HSEL,
  input  logic [DATA_WIDTH-1:0]  ext_periph_HRDATA,
  input  logic                   ext_periph_HREADYOUT,
  input  logic                   ext_periph_HRESP

`ifdef DEBUG_PERIPH
  ,
  // Debug (slot 6)
  output logic [ADDR_WIDTH-1:0]  debug_HADDR,
  output logic [2:0]             debug_HBURST,
  output logic                   debug_HMASTLOCK,
  output logic [3:0]             debug_HPROT,
  output logic [2:0]             debug_HSIZE,
  output logic [1:0]             debug_HTRANS,
  output logic [DATA_WIDTH-1:0]  debug_HWDATA,
  output logic                   debug_HWRITE,
  output logic                   debug_HREADYIN,
  output logic                   debug_HSEL,
  input  logic [DATA_WIDTH-1:0]  debug_HRDATA,
  input  logic                   debug_HREADYOUT,
  input  logic                   debug_HRESP
`endif
);

  // Slot numbering. These index hsel / mux_sel and the response arrays below,
  // and must stay in step with the address decode.
  localparam int SLOT_UART       = 0;
  localparam int SLOT_GPIO_CTRL  = 1;
  localparam int SLOT_QPSI       = 2;
  localparam int SLOT_SPI_M      = 3;
  localparam int SLOT_SPI_S      = 4;
  localparam int SLOT_EXT_PERIPH = 5;

  localparam logic [ADDR_WIDTH-1:0] QSPI_MEM_SIZE = 32'h0080_0000;
`ifdef DEBUG_PERIPH
  localparam int SLOT_DEBUG      = 6;
`endif

  // Response side of each slot, as seen by the interconnect: every slot is
  // unbuffered, so this is the peripheral's own response.
  logic [NUM_SLAVES-1:0]                 slot_HREADYOUT;
  logic [NUM_SLAVES-1:0]                 slot_HRESP;
  logic [NUM_SLAVES-1:0][DATA_WIDTH-1:0] slot_HRDATA;

  logic [NUM_SLAVES-1:0] hsel;
  logic [NUM_SLAVES-1:0] mux_sel;
  logic                  invalid_addr;
  logic                  invalid_addr_r;
  logic                  qspi_reg_sel;
  logic                  qspi_mem_sel;
  logic [ADDR_WIDTH-1:0] qspi_mem_offset;

  // --- Address decode --------------------------------------------------------

  always_comb begin
    invalid_addr = '0;
    hsel = '0;
    qspi_reg_sel = 1'b0;
    qspi_mem_sel = 1'b0;
    case (HADDR) inside
      
      // Everything sits in the 0x8000_0000 aperture.
      // step with AHB_*_BASE in sw/src/config.h.

      [32'h8000_3000 : 32'h8000_3fff]: hsel[SLOT_UART]       = '1; // UART - 4KiB
      [32'h8000_4000 : 32'h8000_4fff]: hsel[SLOT_GPIO_CTRL]  = '1; // GPIO - 4KiB
      [32'h8000_5000 : 32'h8000_5fff]: begin
        hsel[SLOT_QPSI] = '1;
        qspi_reg_sel = 1'b1;
      end
      [32'h8000_6000 : 32'h8000_6fff]: hsel[SLOT_SPI_M]      = '1; // SPI Master - 4KiB
      [32'h8000_7000 : 32'h8000_7fff]: hsel[SLOT_SPI_S]      = '1; // SPI Slave  - 4KiB
      [32'h8001_0000 : 32'h8001_ffff]: hsel[SLOT_EXT_PERIPH] = '1; // External Peripherals - 64KiB
    `ifdef DEBUG_PERIPH
      [32'hf8000_2000 : 32'hf8000_2fff]: hsel[SLOT_DEBUG]      = '1; // Debug - 4KiB
    `endif
      default: begin
        if ((HADDR >= QSPI_MEM_BASE) && (HADDR < (QSPI_MEM_BASE + QSPI_MEM_SIZE))) begin
          hsel[SLOT_QPSI] = '1;
          qspi_mem_sel = 1'b1;
        end else begin
          invalid_addr = 1'b1;
        end
      end
    endcase
  end

  // The decode belongs to the address phase; the response mux and HRESP belong
  // to the data phase, so both are registered on the same HREADY beat.
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      mux_sel        <= '0;
      invalid_addr_r <= '0;
    end
    else if (HREADY) begin
      mux_sel        <= hsel;
      invalid_addr_r <= invalid_addr && HTRANS[1]; // Gate on active Transaction
    end
  end

  // --- Peripheral subsystem (L2 fabric) --------------------------------------
  //
  // Unbuffered slots. Every slave sees the CPU's address phase unchanged; only
  // HSEL differs, and HREADYIN is the muxed bus HREADY.

  assign uart_HADDR                 = HADDR;
  assign uart_HBURST                = HBURST;
  assign uart_HMASTLOCK             = HMASTLOCK;
  assign uart_HPROT                 = HPROT;
  assign uart_HSIZE                 = HSIZE;
  assign uart_HTRANS                = HTRANS;
  assign uart_HWDATA                = HWDATA;
  assign uart_HWRITE                = HWRITE;
  assign uart_HREADYIN              = HREADY;
  assign uart_HSEL                  = hsel[SLOT_UART];
  assign slot_HRDATA[SLOT_UART]     = uart_HRDATA;
  assign slot_HREADYOUT[SLOT_UART]  = uart_HREADYOUT;
  assign slot_HRESP[SLOT_UART]      = uart_HRESP;

  assign gpio_ctrl_HADDR                 = HADDR;
  assign gpio_ctrl_HBURST                = HBURST;
  assign gpio_ctrl_HMASTLOCK             = HMASTLOCK;
  assign gpio_ctrl_HPROT                 = HPROT;
  assign gpio_ctrl_HSIZE                 = HSIZE;
  assign gpio_ctrl_HTRANS                = HTRANS;
  assign gpio_ctrl_HWDATA                = HWDATA;
  assign gpio_ctrl_HWRITE                = HWRITE;
  assign gpio_ctrl_HREADYIN              = HREADY;
  assign gpio_ctrl_HSEL                  = hsel[SLOT_GPIO_CTRL];
  assign slot_HRDATA[SLOT_GPIO_CTRL]     = gpio_ctrl_HRDATA;
  assign slot_HREADYOUT[SLOT_GPIO_CTRL]  = gpio_ctrl_HREADYOUT;
  assign slot_HRESP[SLOT_GPIO_CTRL]      = gpio_ctrl_HRESP;

  assign qpsi_HADDR                 = HADDR;
  assign qpsi_HBURST                = HBURST;
  assign qpsi_HMASTLOCK             = HMASTLOCK;
  assign qpsi_HPROT                 = HPROT;
  assign qpsi_HSIZE                 = HSIZE;
  assign qpsi_HTRANS                = HTRANS;
  assign qpsi_HWDATA                = HWDATA;
  assign qpsi_HWRITE                = HWRITE;
  assign qpsi_HREADYIN              = HREADY;
  assign qpsi_HSEL                  = qspi_reg_sel;
  assign qpsi_HMEMSEL               = qspi_mem_sel;
  assign qspi_mem_offset            = HADDR - QSPI_MEM_BASE;
  assign qpsi_HMEMADDR              = qspi_mem_offset[22:0];
  assign slot_HRDATA[SLOT_QPSI]     = qpsi_HRDATA;
  assign slot_HREADYOUT[SLOT_QPSI]  = qpsi_HREADYOUT;
  assign slot_HRESP[SLOT_QPSI]      = qpsi_HRESP;

  assign spi_m_HADDR                 = HADDR;
  assign spi_m_HBURST                = HBURST;
  assign spi_m_HMASTLOCK             = HMASTLOCK;
  assign spi_m_HPROT                 = HPROT;
  assign spi_m_HSIZE                 = HSIZE;
  assign spi_m_HTRANS                = HTRANS;
  assign spi_m_HWDATA                = HWDATA;
  assign spi_m_HWRITE                = HWRITE;
  assign spi_m_HREADYIN              = HREADY;
  assign spi_m_HSEL                  = hsel[SLOT_SPI_M];
  assign slot_HRDATA[SLOT_SPI_M]     = spi_m_HRDATA;
  assign slot_HREADYOUT[SLOT_SPI_M]  = spi_m_HREADYOUT;
  assign slot_HRESP[SLOT_SPI_M]      = spi_m_HRESP;

  assign spi_s_HADDR                 = HADDR;
  assign spi_s_HBURST                = HBURST;
  assign spi_s_HMASTLOCK             = HMASTLOCK;
  assign spi_s_HPROT                 = HPROT;
  assign spi_s_HSIZE                 = HSIZE;
  assign spi_s_HTRANS                = HTRANS;
  assign spi_s_HWDATA                = HWDATA;
  assign spi_s_HWRITE                = HWRITE;
  assign spi_s_HREADYIN              = HREADY;
  assign spi_s_HSEL                  = hsel[SLOT_SPI_S];
  assign slot_HRDATA[SLOT_SPI_S]     = spi_s_HRDATA;
  assign slot_HREADYOUT[SLOT_SPI_S]  = spi_s_HREADYOUT;
  assign slot_HRESP[SLOT_SPI_S]      = spi_s_HRESP;

  assign ext_periph_HADDR                 = HADDR;
  assign ext_periph_HBURST                = HBURST;
  assign ext_periph_HMASTLOCK             = HMASTLOCK;
  assign ext_periph_HPROT                 = HPROT;
  assign ext_periph_HSIZE                 = HSIZE;
  assign ext_periph_HTRANS                = HTRANS;
  assign ext_periph_HWDATA                = HWDATA;
  assign ext_periph_HWRITE                = HWRITE;
  assign ext_periph_HREADYIN              = HREADY;
  assign ext_periph_HSEL                  = hsel[SLOT_EXT_PERIPH];
  assign slot_HRDATA[SLOT_EXT_PERIPH]     = ext_periph_HRDATA;
  assign slot_HREADYOUT[SLOT_EXT_PERIPH]  = ext_periph_HREADYOUT;
  assign slot_HRESP[SLOT_EXT_PERIPH]      = ext_periph_HRESP;

`ifdef DEBUG_PERIPH
  assign debug_HADDR                 = HADDR;
  assign debug_HBURST                = HBURST;
  assign debug_HMASTLOCK             = HMASTLOCK;
  assign debug_HPROT                 = HPROT;
  assign debug_HSIZE                 = HSIZE;
  assign debug_HTRANS                = HTRANS;
  assign debug_HWDATA                = HWDATA;
  assign debug_HWRITE                = HWRITE;
  assign debug_HREADYIN              = HREADY;
  assign debug_HSEL                  = hsel[SLOT_DEBUG];
  assign slot_HRDATA[SLOT_DEBUG]     = debug_HRDATA;
  assign slot_HREADYOUT[SLOT_DEBUG]  = debug_HREADYOUT;
  assign slot_HRESP[SLOT_DEBUG]      = debug_HRESP;
`endif

  // --- Response mux ----------------------------------------------------------
  // Split signals into their own processes to avoid lint issues with multiple drivers on the same signal

  always_comb begin
    HREADY = 1;
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) HREADY = slot_HREADYOUT[j];
  end

  always_comb begin
    HRESP   = invalid_addr_r;
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) HRESP = slot_HRESP[j];
  end

  always_comb begin
    HRDATA  = 32'hBAADBEEF;  // "hexspeak" to indicate an error has occured
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) begin
        HRDATA  = slot_HRDATA[j];
      end
  end

  // TODO - Add appropriate decoder error response for bad addresses? (2 cycle response)

endmodule
