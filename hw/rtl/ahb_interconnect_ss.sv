module ahb_interconnect_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
`ifdef DEBUG_PERIPH
  localparam int NUM_SLAVES = 9
`else
  localparam int NUM_SLAVES = 8
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

  // Decoder master ports (Peripherals)
  ahb3lite_intf.master           ahb_rom_m,
  ahb3lite_intf.master           ahb_ram_m,
  ahb3lite_intf.master           ahb_uart_m,
  ahb3lite_intf.master           ahb_gpio_ctrl_m,
  ahb3lite_intf.master           ahb_qpsi_m,
  ahb3lite_intf.master           ahb_spi_m_m,
  ahb3lite_intf.master           ahb_spi_s_m,
`ifdef DEBUG_PERIPH
  ahb3lite_intf.master           ahb_debug_m,
`endif
  ahb3lite_intf.master           ahb_ext_periph_m
);

  // Internal MUX signals
  logic [NUM_SLAVES-1:0] HREADYOUT_SIGNALS;
  logic [NUM_SLAVES-1:0] HRESP_SIGNALS;

  logic [DATA_WIDTH-1:0] HRDATA_SIGNALS [NUM_SLAVES-1:0];

  logic [NUM_SLAVES-1:0] hsel;
  logic [NUM_SLAVES-1:0] mux_sel;
  logic                  invalid_addr;

  ahb3lite_intf ahb_masters [0:NUM_SLAVES-1] ();

  // Memory Subsystem (L1 Fabric)
  ahb_conn_buff u_ahb_rom_conn (.hclk(HCLK), .hresetn(HRESETn), .ahb_m(ahb_rom_m), .ahb_s(ahb_masters[0].slave));
  ahb_conn_buff u_ahb_ram_conn (.hclk(HCLK), .hresetn(HRESETn), .ahb_m(ahb_ram_m), .ahb_s(ahb_masters[1].slave));
  
  // (Peripheral subsystem L2 Fabric) 
  ahb_conn u_ahb_uart_conn       (.ahb_m(ahb_uart_m),       .ahb_s(ahb_masters[2].slave));
  ahb_conn u_ahb_gpio_ctrl_conn  (.ahb_m(ahb_gpio_ctrl_m),  .ahb_s(ahb_masters[3].slave));
  ahb_conn u_ahb_qpsi_conn       (.ahb_m(ahb_qpsi_m),       .ahb_s(ahb_masters[4].slave));
  ahb_conn u_ahb_spi_master_conn (.ahb_m(ahb_spi_m_m),      .ahb_s(ahb_masters[5].slave));
  ahb_conn u_ahb_spi_slave_conn  (.ahb_m(ahb_spi_s_m),      .ahb_s(ahb_masters[6].slave));
  ahb_conn u_ahb_ext_periph_conn (.ahb_m(ahb_ext_periph_m), .ahb_s(ahb_masters[7].slave));

`ifdef DEBUG_PERIPH
  ahb_conn u_ahb_debug_conn (.ahb_m(ahb_debug_m), .ahb_s(ahb_masters[8].slave));
`endif

  always_comb begin
    invalid_addr = '0;
    hsel = '0;
    case (HADDR) inside
      [32'h0000_0000 : 32'h0000_1fff]: hsel[0] = '1; // ROM  - 4KiB
      [32'h0000_2000 : 32'h0000_2fff]: hsel[1] = '1; // RAM  - 4KiB
      [32'h0000_3000 : 32'h0000_3fff]: hsel[2] = '1; // UART - 4KiB
      [32'h0000_4000 : 32'h0000_4fff]: hsel[3] = '1; // GPIO - 4KiB
      [32'h0000_5000 : 32'h0000_5fff]: hsel[4] = '1; // QPSI - 4KiB
      [32'h0000_6000 : 32'h0000_6fff]: hsel[5] = '1; // SPI Master - 4KiB
      [32'h0000_7000 : 32'h0000_7fff]: hsel[6] = '1; // SPI Slave  - 4KiB
      [32'h0001_0000 : 32'h0001_ffff]: hsel[7] = '1; // External Peripherals - 64KiB
    `ifdef DEBUG_PERIPH
      [32'hf000_2000 : 32'hf000_2fff]: hsel[8] = '1; // Debug - 4KiB
    `endif
      default: invalid_addr = '1;
    endcase
  end

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn)
      mux_sel <= '0;
    else if (HREADY)
      mux_sel <= hsel;

  genvar i;
  generate
    for (i = 0; i < NUM_SLAVES; i++) begin : gen_slave
      always_comb begin
        ahb_masters[i].HADDR      = HADDR;
        ahb_masters[i].HBURST     = HBURST;
        ahb_masters[i].HMASTLOCK  = HMASTLOCK;
        ahb_masters[i].HPROT      = HPROT;
        ahb_masters[i].HSIZE      = HSIZE;
        ahb_masters[i].HTRANS     = HTRANS;
        ahb_masters[i].HWDATA     = HWDATA;
        ahb_masters[i].HWRITE     = HWRITE;
        HREADYOUT_SIGNALS[i]      = ahb_masters[i].HREADYOUT;
        HRESP_SIGNALS[i]          = ahb_masters[i].HRESP;
        HRDATA_SIGNALS[i]         = ahb_masters[i].HRDATA;
        ahb_masters[i].HREADYIN   = HREADY;
        ahb_masters[i].HSEL       = hsel[i];
      end
    end
  endgenerate

  // Split signals into their own processes to avoid lint issues with multiple drivers on the same signal
  always_comb begin
    HREADY = 1;
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) HREADY = HREADYOUT_SIGNALS[j];
  end

  always_comb begin
    HRESP   = invalid_addr;
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) HRESP = HRESP_SIGNALS[j];
  end

  always_comb begin
    HRDATA  = 32'hBAADBEEF;  // "hexspeak" to indicate an error has occured
    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) begin
        HRDATA  = HRDATA_SIGNALS[j];
      end
  end

  // TODO - Add appropriate decoder error response (2 cycle response)

endmodule
