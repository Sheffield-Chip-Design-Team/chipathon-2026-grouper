// AHB-Lite placeholder slave
//
// Stand-in for peripherals that don't have RTL yet (SPI Master, QSPI,
// GPIO Mux, and the reserved External Peripheral window). It occupies its
// slot on the fabric so accesses complete instead of hanging the bus, and
// flags every access as an error (HRESP) so software notices it hit an
// unimplemented block. Swap the instance out for the real peripheral as
// each one lands.

module ahb_stub_slave #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL
);

  import ahb3lite_pkg::*;

  // Register the address-phase access into the data phase, matching the
  // pipelining of the other peripheral register blocks in this repo.
  logic access_r;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (!HRESETn)
      access_r <= '0;
    else
      access_r <= HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);

  assign HRDATA    = '0;
  assign HREADYOUT = 1'b1; // Single cycle response, zero wait states.

  // FIXME - add 2-cycle error response for spec-compliant SLVERR, same as
  // the TODO already flagged in ahb_interconnect.sv.
  assign HRESP     = access_r;

endmodule
