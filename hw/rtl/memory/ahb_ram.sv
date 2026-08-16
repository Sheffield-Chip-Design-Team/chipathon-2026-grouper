// This module is an AHB-Lite Slave containing a RAM
//
// Number of addressable locations : 2**MEM_WIDTH
// Size of each addressable location : 8 bits
// Supported transfer sizes : Word, Halfword, Byte
// Alignment of base address : Word aligned
//
// Under `DRY_RUN the memory array is replaced by counters on the address and
// data lines - a placeholder for the hardened SRAM macros. See the comment on
// that branch below.

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

`ifdef DRY_RUN

  // Placeholder for the hardened gf180mcu_ocd_ip_sram macros, which are out of
  // scope for the dry run (see librelane/classic/dry_run_config.yaml). Two
  // ADDR_WIDTH counters sit on the address and data lines: they load from the
  // bus on an access and free-run otherwise, which keeps HADDR, HWDATA and the
  // HSIZE-derived byte selects electrically live so synthesis cannot prune the
  // RAM leg of the fabric, and gives HRDATA a real driver -- without paying for
  // the MEM_WORDS x DATA_WIDTH flop array the behavioural model would infer.
  //
  // Not a memory: reads do not return what was written. Only the DRY_RUN
  // configuration builds this path.

  logic [ADDR_WIDTH-1:0] addr_cnt;
  logic [ADDR_WIDTH-1:0] data_cnt;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      addr_cnt <= '0;
      data_cnt <= '0;
    end else begin
      // HADDR whole, not the MEM_WIDTH slice word_address takes: the point is
      // to load every address bit, including the ones a real RAM would ignore.
      addr_cnt <= access       ? ADDR_WIDTH'(HADDR) : addr_cnt + 1'b1;
      data_cnt <= write_enable ? ADDR_WIDTH'(HWDATA) ^ ADDR_WIDTH'(byte_select_r)
                               : data_cnt + 1'b1;
    end

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn)
      HRDATA <= '0;
    else if (read_enable)
      HRDATA <= DATA_WIDTH'(data_cnt ^ addr_cnt);

  // The address decode is bypassed above (addr_cnt takes HADDR directly) and
  // byte_select is consumed only through its registered copy, so both of these
  // are dead on this path. Kept declared so the two branches share one decode.
  logic _unused_dry_run;
  assign _unused_dry_run = &{1'b0, byte_select, word_address, word_address_r};

`else

  // Memory Array
  logic [DATA_WIDTH-1:0] memory [0:MEM_WORDS-1];

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

`endif

  //Transfer Response
  assign HREADYOUT = '1; // Single cycle Write & Read. Zero Wait state operations
  assign HRESP     = '0; // Success

endmodule
