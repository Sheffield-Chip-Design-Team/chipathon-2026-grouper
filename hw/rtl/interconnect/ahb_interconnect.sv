module ahb_interconnect #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
`ifdef DEBUG_PERIPH
  localparam int NUM_SLAVES = 4
`else
  localparam int NUM_SLAVES = 3
`endif
) (
  input logic HCLK,
  input logic HRESETn,

  // Decoder master ports
  ahb3lite_intf.master ahb_rom_m,
  ahb3lite_intf.master ahb_ram_m,
  ahb3lite_intf.master ahb_uart_m,
`ifdef DEBUG_PERIPH
  ahb3lite_intf.master ahb_debug_m,
`endif

  // AHB Slave Interface
  
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
  output logic                   HRESP
);

  logic [NUM_SLAVES-1:0] HREADYOUT_SIGNALS;
  logic [NUM_SLAVES-1:0] HRESP_SIGNALS;
  logic [DATA_WIDTH-1:0] HRDATA_SIGNALS [NUM_SLAVES-1:0];

  logic [NUM_SLAVES-1:0] hsel;
  logic [NUM_SLAVES-1:0] mux_sel;

  ahb3lite_intf ahb_masters [0:NUM_SLAVES-1] ();
  ahb_conn u_ahb_rom_conn (.ahb_m(ahb_rom_m), .ahb_s(ahb_masters[0].slave));
  ahb_conn u_ahb_ram_conn (.ahb_m(ahb_ram_m), .ahb_s(ahb_masters[1].slave));
  ahb_conn u_ahb_uart_conn (.ahb_m(ahb_uart_m), .ahb_s(ahb_masters[2].slave));
`ifdef DEBUG_PERIPH
  ahb_conn u_ahb_debug_conn (.ahb_m(ahb_debug_m), .ahb_s(ahb_masters[3].slave));
`endif

  logic invalid_addr;

  always_comb begin
    invalid_addr = '0;
    hsel = '0;
    case (HADDR) inside
      [32'h0000_0000 : 32'h7fff_ffff]: hsel[0] = '1; // ROM
      [32'h8000_0000 : 32'h8fff_ffff]: hsel[1] = '1; // RAM
      [32'h9000_0000 : 32'h9000_000f]: hsel[2] = '1; // UART
`ifdef DEBUG_PERIPH
      [32'hf000_0000 : 32'hffff_ffff]: hsel[3] = '1; // Debug
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

  always_comb begin
    HREADY  = 1;
    HRDATA  = 32'hBAADBEEF;  // "hexspeak" to indicate an error has occured
    HRESP   = invalid_addr;

    for (int j = 0; j < NUM_SLAVES; j++)
      if (mux_sel[j] == 1'b1) begin
        HREADY  = HREADYOUT_SIGNALS[j];
        HRESP   = HRESP_SIGNALS[j];
        HRDATA  = HRDATA_SIGNALS[j];
      end
  end

endmodule
