// AHB Debug Interface
//
// Number of addressable locations : 256
// Size of each addressable location : 32 bits
// Supported transfer sizes : Word
// Alignment of base address : Double Word aligned
//
// Address map :
//   Base addess + 0 - 253 :
//     Write Debug Value (Runs the debug)
//   Base addess + 254 :
//     Instruction trace control - only when TRACE_EN, otherwise this location
//     behaves like any other debug value location.
//     Write bit 0 = 1 to start capturing the CPU instruction trace, 0 to stop.
//     Reads back bit 0 = capture currently running.
//   Base addess + 255 :
//     If upper byte is written, it will call $write("%c") with it
//     Write Debug Value (Runs the debug)
//     if 'hDEAD600D written $finish is called
//     if 'hDEADDEAD written $stop is called
//
// Instruction trace (optional, TRACE_EN):
//   picorv32 emits one 36-bit record per retired instruction when it is built
//   with ENABLE_TRACE (cpu_ss ENABLE_TRACE, driven by the CPU_TRACE define).
//   Records are written raw - one hex value per line - to TRACE_FILE, which is
//   the format picorv32's showtrace.py expects:
//     fusesoc_libraries/picorv32/showtrace.py cpu.trace sw/build/firmware.elf
//   Capture starts at time 0 when TRACE_AUTOSTART is set, and can be windowed
//   from firmware around a region of interest with debug_trace() (sw/src/debug).

`ifndef CPU_TRACE_FILE
`define CPU_TRACE_FILE "cpu.trace"
`endif

module ahb_debug #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int DEBUG_ADDR_WIDTH = 8,
  parameter bit TRACE_EN = 1'b0,          // capture the CPU instruction trace
  parameter bit TRACE_AUTOSTART = 1'b1,   // start capturing without a firmware write
  parameter bit TRACE_CONSOLE = 1'b0,     // also decode each record to the console
  parameter string TRACE_FILE = `CPU_TRACE_FILE,
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
  input logic                   HSEL,

  // picorv32 trace Interface (only sampled when TRACE_EN)
  input logic                   trace_valid,
  input logic [35:0]            trace_data
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

  // Act on control signals in the data phase

  localparam logic [DEBUG_ADDR_WIDTH-1:0] TRACE_CTRL_ADDR = 'hFE;
  localparam logic [DEBUG_ADDR_WIDTH-1:0] MAGIC_ADDR      = 'hFF;

  logic [DEBUG_ADDR_WIDTH-1:0] debug_address;
  logic                        trace_ctrl_access;

  assign debug_address     = word_address[DEBUG_ADDR_WIDTH-1:0];
  assign trace_ctrl_access = TRACE_EN && (debug_address == TRACE_CTRL_ADDR);

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
      if (debug_address == MAGIC_ADDR && byte_address == '1 && byte_select == (1 << (DATA_WIDTH/8-1))) begin
        // Print a character, when writing to upper byte of 'hFF
        $write("%c", HWDATA[DATA_WIDTH-1 -: 8]);
      end else if (trace_ctrl_access) begin
        // Trace control - handled by the instruction trace block below
      end else begin
        $display("Debug: 0x%h", debug_address, " = ", HWDATA, "(%d) (0x%h)", $signed(HWDATA), HWDATA, " @ %8t", $realtime, " | dt=%8t", $realtime - last_debug, " | dt2=%8t", $realtime - last_debugs[debug_address]);
        last_debug <= $realtime;
        last_debugs[debug_address] <= $realtime;
        if (debug_address == MAGIC_ADDR && HWDATA == 'hDEAD600D) $finish;  // Magic stop code
        if (debug_address == MAGIC_ADDR && HWDATA == 'hDEADDEAD) $stop;    // Magic stop code
      end
    end

  // Optional instruction trace
  //
  // Sim-only: capture picorv32's trace stream to TRACE_FILE while capture is
  // running. Everything below collapses to nothing when TRACE_EN is 0.

  int          trace_fd;
  int unsigned trace_records;
  logic        trace_on;

  initial begin
    trace_fd      = 0;
    trace_records = 0;
    trace_on      = TRACE_EN && TRACE_AUTOSTART;
    if (TRACE_EN) begin
      trace_fd = $fopen(TRACE_FILE, "w");
      if (trace_fd == 0)
        $fatal(1, "ahb_debug: could not open instruction trace file '%s' for writing", TRACE_FILE);
    end
  end

  // Trace control register
  always_ff @(posedge HCLK)
    if (write_enable && trace_ctrl_access && (trace_on != HWDATA[0])) begin
      trace_on <= HWDATA[0];
      if (!HWDATA[0]) $fflush(trace_fd);
      $display("Debug: instruction trace %s @ %8t", HWDATA[0] ? "started" : "stopped", $realtime);
    end

  // Trace capture
  always_ff @(posedge HCLK)
    if (TRACE_EN && trace_on && trace_valid) begin
      $fwrite(trace_fd, "%x\n", trace_data);
      // Flush every record so a testbench can read the tail of the trace
      // while the simulation is still running. 
      $fflush(trace_fd);
      trace_records <= trace_records + 1;
      if (TRACE_CONSOLE)
        // Same record decode as picorv32's showtrace.py: branch target ('>'),
        // memory address ('@') or register write-back value ('=')
        $display("Trace: %s %s0x%h @ %8t",
                 trace_data[35] ? "IRQ" : "   ",
                 trace_data[32] ? ">" : (trace_data[33] ? "@" : "="),
                 trace_data[31:0], $realtime);
    end

  final begin
    if (TRACE_EN) begin
      $fclose(trace_fd);
      $display("Debug: wrote %0d instruction trace records to '%s'", trace_records, TRACE_FILE);
    end
  end

  // read
  // Only the trace control register reads back, everything else is write-only
  assign HRDATA = (trace_ctrl_access) ? {{(DATA_WIDTH-1){1'b0}}, trace_on} : '0;

  //Transfer Response
  assign HREADYOUT = '1; //Single cycle Write & Read. Zero Wait state operations
  assign HRESP     = '0; // Never Fail. Always OKAY response

endmodule

