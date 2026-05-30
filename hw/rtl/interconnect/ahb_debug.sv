// AHB Debug Interface
//
// Number of addressable locations : 256
// Size of each addressable location : 32 bits
// Supported transfer sizes : Word
// Alignment of base address : Double Word aligned
//
// Address map :
//   Base addess + 0 - 254 : 
//     Write Debug Value (Runs the debug)
//   Base addess + 255 : 
//     If upper byte is written, it will call $write("%c") with it
//     Write Debug Value (Runs the debug)
//     if 'hDEAD600D written $finish is called
//     if 'hDEADDEAD written $stop is called

module ahb_debug #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int DEBUG_ADDR_WIDTH = 8,
  localparam int BYTE_ADDR_WIDTH = $clog2(DATA_WIDTH/8),
  localparam int WORD_ADDR_WIDTH = ADDR_WIDTH - BYTE_ADDR_WIDTH
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

  timeunit 1ns/100ps;

  import ahb3lite_pkg::*;

  //control signals are stored in registers
  logic                       write_enable;
  logic [WORD_ADDR_WIDTH-1:0] word_address;
  logic [BYTE_ADDR_WIDTH-1:0] byte_address;
  logic [(DATA_WIDTH/8)-1:0]  byte_select;

  //Generate the control signals in the address phase
  always_ff @(posedge HCLK, negedge HRESETn)
    if (!HRESETn) begin
      write_enable <= '0;
      word_address <= '0;
      byte_address <= '0;
      byte_select  <= '0;
    end else if (HREADYIN && HSEL && (HTRANS != HTRANS_IDLE)) begin
      write_enable <= HWRITE;
      word_address <= HADDR[BYTE_ADDR_WIDTH +: WORD_ADDR_WIDTH];
      byte_address <= HADDR[BYTE_ADDR_WIDTH-1:0];
      byte_select  <= generate_byte_select_32(HSIZE, HADDR[BYTE_ADDR_WIDTH-1:0]);
    end else begin
      write_enable <= '0;
      word_address <= '0;
      byte_address <= '0;
      byte_select  <= '0;
    end

  //Act on control signals in the data phase

  real last_debug;
  real last_debugs [0:(2**DEBUG_ADDR_WIDTH)-1];

  initial begin
    $timeformat(-3, 2, "ms", 8);
    last_debug = 0;
    for (int i = 0; i < 2**DEBUG_ADDR_WIDTH; i++)
      last_debugs[i] = 0;
  end

  // write
  always_ff @(posedge HCLK)
    if (write_enable) begin
      if (word_address[DEBUG_ADDR_WIDTH-1:0] == 'hFF && byte_address == '1 && byte_select == (1 << (DATA_WIDTH/8-1))) begin
        // Print a character, when writing to upper byte of 'hFF
        $write("%c", HWDATA[DATA_WIDTH-1 -: 8]);
      end else begin
        $display("Debug: 0x%h", word_address[DEBUG_ADDR_WIDTH-1:0], " = ", HWDATA, "(%d) (0x%h)", $signed(HWDATA), HWDATA, " @ %8t", $realtime, " | dt=%8t", $realtime - last_debug, " | dt2=%8t", $realtime - last_debugs[word_address[DEBUG_ADDR_WIDTH-1:0]]);
        last_debug <= $realtime;
        last_debugs[word_address[DEBUG_ADDR_WIDTH-1:0]] <= $realtime;
        if (word_address[DEBUG_ADDR_WIDTH-1:0] == 'hFF && HWDATA == 'hDEAD600D) $finish;  // Magic stop code
        if (word_address[DEBUG_ADDR_WIDTH-1:0] == 'hFF && HWDATA == 'hDEADDEAD) $stop;    // Magic stop code
      end
    end

  // read
  // Nothing to read
  assign HRDATA = '0;

  //Transfer Response
  assign HREADYOUT = '1; //Single cycle Write & Read. Zero Wait state operations
  assign HRESP     = '0; // Success

endmodule

