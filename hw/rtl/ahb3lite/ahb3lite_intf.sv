interface ahb3lite_intf #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32
) ();

  // Master Signals
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
  logic                   HREADYOUT;
  logic                   HRESP;

  // Decoder Signals
  logic                   HREADYIN; // Signal from decoder to slave so it knows when the data phase is
  logic                   HSEL; // Master should just tie this high (it shouldn't really output this)

  modport master (
    output HADDR,
    output HBURST,
    output HMASTLOCK,
    output HPROT,
    output HSIZE,
    output HTRANS,
    output HWDATA,
    output HWRITE,
    input  HRDATA,
    input  HREADYOUT,
    input  HRESP,
    output HREADYIN,
    output HSEL
  );

  modport slave (
    input  HADDR,
    input  HBURST,
    input  HMASTLOCK,
    input  HPROT,
    input  HSIZE,
    input  HTRANS,
    input  HWDATA,
    input  HWRITE,
    output HRDATA,
    output HREADYOUT,
    output HRESP,
    input  HREADYIN,
    input  HSEL
  );

endinterface
