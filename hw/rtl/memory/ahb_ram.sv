// This module is an AHB-Lite Slave containing a RAM
//
// Number of addressable locations : 2**MEM_WIDTH
// Size of each addressable location : 8 bits
// Supported transfer sizes : Word, Halfword, Byte
// Alignment of base address : Word aligned
//
// Storage comes from one of two places:
//
//   `MACRO_RAM   four hardened gf180mcu_ocd_ip_sram__sram1024x8m8wm1 macros,
//                one per byte lane, instantiated through ram_ss. This is the
//                path both LibreLane flows build; it is what the MACROS block
//                in librelane/classic/config.yaml places.
//   otherwise    a behavioural array, for simulation.
//
// Both are 4 KiB (MEM_WIDTH 12), which is the RAM window the interconnect
// decodes (0x0000_2000-0x0000_2fff) and exactly four 1024x8 macros.

module ahb_ram #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int MEM_WIDTH = 12,
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

`ifdef MACRO_RAM

  // Hardened storage: ram_ss instantiates four sram1024x8m8wm1 macros, one per
  // byte lane, sharing an address. Single-port synchronous SRAM -- A, CEN,
  // GWEN, WEN and D are captured on the clock edge, and Q is valid throughout
  // the cycle that follows.
  //
  // That lines up with AHB with no read-latency and no read-data register of
  // our own; the macro's own output register is the one AHB needs:
  //
  //   read   address phase in cycle N drives A, so Q is valid in N+1, which is
  //          the data phase. HRDATA is Q, straight through.
  //   write  HWDATA only exists in the data phase, so the macro is driven from
  //          the registered address and byte strobes one cycle later instead.
  //
  // The single port is the only contention point, and only one sequence hits
  // it: a read whose address phase falls in a write's data phase, where the
  // write wants the port in the same cycle the read does. HREADYOUT below
  // spends one wait state there. Everything else -- back-to-back reads,
  // back-to-back writes, write after read -- runs at zero wait states.
  //
  // The macros have no reset. Contents are undefined out of reset, exactly as
  // on silicon; firmware must not read RAM it has not written.

  logic [WORD_ADDR_WIDTH-1:0] sram_addr;
  logic                       sram_read;
  logic                       sram_write;

  assign sram_write = write_enable;
  assign sram_read  = access & read_enable;
  assign sram_addr  = write_enable ? word_address_r : word_address;

  ram_ss #(
    .ADDR_WIDTH    (WORD_ADDR_WIDTH),
    .USE_MACRO_RAM (1)
  ) u_ram_ss (
    .clk       (HCLK),
    .rst_n     (HRESETn),
    .ram_addr  (sram_addr),
    .ram_read  (sram_read),
    .ram_write (sram_write),
    .ram_wdata (HWDATA),
    .ram_wstrb (byte_select_r),
    .ram_rdata (HRDATA)
  );

  // byte_select is consumed through its registered copy only; the unregistered
  // copy exists so both branches share one address/strobe decode.
  logic _unused_macro_ram;
  assign _unused_macro_ram = &{1'b0, byte_select};

  // ram_ss is four 8-bit macros wide by construction, and the macro is 1024
  // words deep. Neither is a parameter that can flex.
`ifndef SYNTHESIS
  initial
    if (DATA_WIDTH != 32 || WORD_ADDR_WIDTH != 10)
      $fatal(1, "ahb_ram: MACRO_RAM needs DATA_WIDTH 32 and MEM_WIDTH 12, got %0d/%0d",
             DATA_WIDTH, MEM_WIDTH);
`endif

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
`ifdef MACRO_RAM
  // One wait state for a read presented while a write is still using the
  // single SRAM port (see the MACRO_RAM branch above); zero otherwise.
  //
  // Deliberately a function of HSEL/HTRANS/HWRITE and not of HREADYIN: an AHB
  // slave may decode the address phase combinationally into HREADYOUT, but
  // ahb_conn_buff feeds our HREADYOUT straight back as our HREADYIN
  // (m_HREADYIN = m_HREADYOUT), so any HREADYIN term here would close a
  // combinational loop. `access` still gates on HREADYIN, so the stalled read
  // is not issued to the macro during the wait cycle -- the write is, and the
  // read re-presents its address phase in the cycle after.
  assign HREADYOUT = ~(write_enable & HSEL & ~HWRITE & (HTRANS != HTRANS_IDLE));
`else
  assign HREADYOUT = '1; // Single cycle Write & Read. Zero Wait state operations
`endif
  assign HRESP     = '0; // Success

endmodule
