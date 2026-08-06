// This module is an AHB-Lite Slave containing a RAM
//
// Number of addressable locations : 2**MEM_WIDTH
// Size of each addressable location : 8 bits
// Supported transfer sizes : Word, Halfword, Byte
// Alignment of base address : Word aligned

module ahb_ram #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int MEM_WIDTH = 11,
  localparam int BYTE_ADDR_WIDTH = $clog2(DATA_WIDTH/8),
  localparam int WORD_ADDR_WIDTH = MEM_WIDTH - BYTE_ADDR_WIDTH,
  localparam int MEM_WORDS = 2**WORD_ADDR_WIDTH
) (
  input logic HCLK,
  input logic HRESETn,

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

  // Memory Array  
  logic [DATA_WIDTH-1:0] memory [0:MEM_WORDS-1];

  logic                       access;
  logic                       read_enable;
  logic                       write_enable;
  logic [WORD_ADDR_WIDTH-1:0] word_address;
  logic [WORD_ADDR_WIDTH-1:0] word_address_r;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;
  logic [(DATA_WIDTH/8)-1:0]  byte_select_r;

  assign access       = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);
  assign read_enable  = ~HWRITE;

  assign word_address = access ? HADDR[MEM_WIDTH-1:BYTE_ADDR_WIDTH] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[BYTE_ADDR_WIDTH-1:0]) : '0;

  // Delay write control signals to data phase
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      write_enable    <= '0;
      word_address_r  <= '0;
      byte_select_r   <= '0;
    end else begin
      write_enable    <= access & HWRITE;
      word_address_r  <= word_address;
      byte_select_r   <= byte_select;
    end

  // Write Port
  always_ff @(posedge HCLK)
    if (write_enable)
      for (int i = 0; i < DATA_WIDTH/8; i++)
        if (byte_select_r[i])
          memory[word_address_r][i*8 +: 8] <= HWDATA[i*8 +: 8];

  // Read Port
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn)
      HRDATA <= '0;
    else if (read_enable)
`ifdef DEBUG_MEM
      // (output of X when not enabled for read is not necessary but may help with debugging)
      for (int i = 0; i < DATA_WIDTH/8; i++)
        HRDATA[i*8 +: 8] <= byte_select[i] ? memory[word_address][i*8 +: 8] : 'x;
    else
      HRDATA <= 'x;
`else
      HRDATA <= memory[word_address];
`endif

  //Transfer Response
  assign HREADYOUT = '1; // Single cycle Write & Read. Zero Wait state operations
  assign HRESP     = '0; // Success

endmodule
