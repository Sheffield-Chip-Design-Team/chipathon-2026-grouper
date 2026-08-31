module cpu_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int ROM_ADDR_WIDTH = 8,
  parameter int RAM_ADDR_WIDTH = 10,
  parameter int NUM_IRQ = 1,
  parameter bit ENABLE_TRACE = 1'b0    
) (
  // Clock and Reset
  input logic                        HCLK,
  input logic                        HRESETn,

  // ROM Interface
  output logic [ROM_ADDR_WIDTH-1:0] rom_addr,
  output logic                      rom_read,
  input  logic [31:0]               rom_rdata,

  // RAM Interface
  output logic [RAM_ADDR_WIDTH-1:0] ram_addr,
  output logic                      ram_read,
  output logic                      ram_write,
  output logic [31:0]               ram_wdata,
  output logic [3:0]                ram_wstrb,
  input  logic [31:0]               ram_rdata,

  // AHB Master Interface
  // Master Signals
  output logic [ADDR_WIDTH-1:0]     HADDR,
  output logic [2:0]                HBURST,
  output logic                      HMASTLOCK,
  output logic [3:0]                HPROT,
  output logic [2:0]                HSIZE,
  output logic [1:0]                HTRANS,
  output logic [DATA_WIDTH-1:0]     HWDATA,
  output logic                      HWRITE,
  // Slave Signals
  input logic [DATA_WIDTH-1:0]      HRDATA,
  input logic                       HREADY,
  input logic                       HRESP,

  // Debug Request port (Slave) (GRPR-DBG-001).
  input  logic                      dbg_req_valid,
  output logic                      dbg_req_ready,
  input  logic [3:0]                dbg_req_cmd,
  input  logic [ADDR_WIDTH-1:0]     dbg_req_addr,
  input  logic [DATA_WIDTH-1:0]     dbg_req_wdata,
  input  logic [1:0]                dbg_req_size,
  output logic                      dbg_rsp_valid,
  input  logic                      dbg_rsp_ready,
  output logic [DATA_WIDTH-1:0]     dbg_rsp_rdata,
  output logic                      dbg_rsp_err,

  // Lock-active indication (GRPR-DBG-044), consumed outside cpu_ss by
  // io_ss's pad-3 output-enable gate.
  output logic                      dbg_lock_active,

  // Interrupts input
  input logic [NUM_IRQ-1:0]         irq,

  // Instruction trace 
  output logic                      trace_valid,
  output logic [35:0]               trace_data
);

  import ahb3lite_pkg::*;

  // -- Internal Signals ------------------------------------------------

  // CLock and Reset
  logic         cpu_rst_n;      // Reset used by CPU
  logic         bus_error;      // AHB bus error

  // Unused CPU outputs
  logic         trap;           // CPU trap signal
  logic         mem_instr;
  logic [31:0]  eoi;

  // Drives the RAM write port
  logic [31:0]           mem_la_wdata;

  // Memory interface
  logic                  mem_valid;
  logic                  mem_ready;      // completion, whoever owns the bus
  logic                  cpu_mem_ready;  // ... as seen by picorv32
  logic [ADDR_WIDTH-1:0] mem_addr;
  logic [DATA_WIDTH-1:0]           mem_wdata;
  logic [ 3:0]           mem_wstrb;
  logic [DATA_WIDTH-1:0]           mem_rdata;

  // Look-Ahead Interface.
  logic                  cpu_la_read;
  logic                  cpu_la_write;
  logic [31:0]           cpu_la_addr;
  logic [31:0]           cpu_la_wdata;
  logic [ 3:0]           cpu_la_wstrb;

  logic                  mem_la_req;     // the owner is actually asking for something
  logic                  mem_la_read;
  logic                  mem_la_write;
  logic [31:0]           mem_la_addr;    // [1:0] always zero - word-aligned by picorv32
  logic [ 3:0]           mem_la_wstrb;

  // IRQ Interface
  logic [31:0]           irq_int;

  // Trace Interface
  logic                  cpu_trace_valid;
  logic [35:0]           cpu_trace_data;

  // Address decode
  logic                  rom_sel;
  logic                  ram_sel;
  logic                  bs_sel;
  logic                  ahb_sel;
  logic                  ram_sel_r;
  logic                  bs_sel_r;
  logic                  ahb_sel_r;

  // AHB decode
  logic [1:0]            HADDR_byte;

  // Debug Unit signals
  logic                  dbg_own;      // debug owns the bus this cycle
  logic                  dbg_req;      // a transfer is being requested
  logic                  dbg_write;
  logic [ADDR_WIDTH-1:0] dbg_addr;
  logic [31:0]           dbg_wdata;
  logic [3:0]            dbg_wstrb;
  logic                  dbg_ready;    // transfer completed this cycle
  logic [31:0]           dbg_rdata;
  logic                  dbg_bus_error; // the just-completed debug transfer errored
  logic                  cpu_freeze;    // stall picorv32 (freeze-style lock, between steps)
  logic                  cpu_rst_req;   // hold picorv32 in reset (reset-style lock)

  // Debug-side Memory registers
  logic [31:0]           dbg_wdata_r;
  logic [31:0]           dbg_addr_r;
  logic [ 3:0]           dbg_wstrb_r;

  // A debug-sourced RAM read waiting on ram_ss's registered output
  // (dbg_ram_read_pending, see the note above dbg_ready's assignment).
  logic                 dbg_ram_read_pending;
  logic                 dbg_bus_active;
  logic                 dbg_ram_read_start;

  // Hidden register for bank switch
  logic                 bank_switch;
  logic                 bank_switch_write;
  logic [31:0]          bank_switch_wdata;
  logic                 bank_switch_valid;

  // IRQ 0-2 Can also be triggered by the CPU internally
  // IRQ 0 - Timer Interrupt
  // IRQ 1 - EBREAK/ECALL or Illegal Instruction
  // IRQ 2 - BUS Error (Unalign Memory Access) + Used for invalid memory address
  assign irq_int = {{(29-NUM_IRQ){1'b0}}, irq, bus_error, 2'b0};

  //--------------------------------------------------------------------------
  // Picorv32 CPU with RV32EMC Configuration + Trace enabled
  //--------------------------------------------------------------------------

  picorv32 #(
    // PICORV32 Configuration Parameters
	  .ENABLE_COUNTERS      (1),
	  .ENABLE_COUNTERS64    (1),
	  .ENABLE_REGS_16_31    (0),  // RV32E: x0-x15 only
	  .ENABLE_REGS_DUALPORT (1),
	  .LATCHED_MEM_RDATA    (0),
	  .TWO_STAGE_SHIFT      (1),
	  .BARREL_SHIFTER       (0),
	  .TWO_CYCLE_COMPARE    (0),
	  .TWO_CYCLE_ALU        (0),
	  .COMPRESSED_ISA       (1),  // RV32*C
	  .CATCH_MISALIGN       (1),
	  .CATCH_ILLINSN        (1),
	  .ENABLE_PCPI          (0),
	  .ENABLE_MUL           (1),
	  .ENABLE_FAST_MUL      (0),
	  .ENABLE_DIV           (1),
	  .ENABLE_IRQ           (1),
	  .ENABLE_IRQ_QREGS     (1),
	  .ENABLE_IRQ_TIMER     (1),
	  .ENABLE_TRACE         (ENABLE_TRACE),
	  .REGS_INIT_ZERO       (0),
	  .MASKED_IRQ           (32'h 0000_0000),
	  .LATCHED_IRQ          (32'h ffff_ffff),
	  .PROGADDR_RESET       (32'h 0000_0000),
	  .PROGADDR_IRQ         (32'h 0000_0010),
	  .STACKADDR            (32'h ffff_ffff)
  ) u_cpu (
    // Clock / Reset
    .clk          (HCLK),
    .resetn       (cpu_rst_n),

    .trap         (trap),

    // Memory interface
    .mem_valid    (mem_valid),
    .mem_instr    (mem_instr),
    .mem_ready    (cpu_mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),

	  // Look-Ahead Interface
    .mem_la_read  (cpu_la_read),
    .mem_la_write (cpu_la_write),
    .mem_la_addr  (cpu_la_addr),
    .mem_la_wdata (cpu_la_wdata),
    .mem_la_wstrb (cpu_la_wstrb),

	  // Pico Co-Processor Interface (PCPI)
	  .pcpi_valid   (),
	  .pcpi_insn    (),
	  .pcpi_rs1     (),
	  .pcpi_rs2     (),
    .pcpi_wr      ('0),
    .pcpi_rd      ('0),
    .pcpi_wait    ('0),
    .pcpi_ready   ('0),

    // IRQ Interface
    .irq          (irq_int),
    .eoi          (eoi),

	  // Trace Interface
    .trace_valid  (cpu_trace_valid),
    .trace_data   (cpu_trace_data)
  );

  // picorv32 leaves trace_data at 'x when ENABLE_TRACE is 0 - don't let that
  // leak out of the subsystem
  assign trace_valid = ENABLE_TRACE && cpu_trace_valid;
  assign trace_data  = ENABLE_TRACE ? cpu_trace_data : '0;

  //--------------------------------------------------------------------------
  // CPU Stall Logic (GRPR-DBG-020, GRPR-DBG-025, GRPR-DBG-027, GRPR-DBG-043)
  //--------------------------------------------------------------------------

  // Holding mem_ready low stalls picorv32 mid-transfer (GRPR-SOC-020).
  // A freeze preserves architectural state because the CPU simply waits: its
  // program counter and register file are untouched, and it resumes on the
  // instruction it stalled on once the freeze lifts.
  //
  // Gated on dbg_own as well as cpu_freeze. cpu_freeze alone is not enough:
  // the two are independent (a STEP or a DBG_RESUME clears cpu_freeze while
  // the lock, and so dbg_own, is still held, GRPR-DBG-025/-027), and in that
  // window the ownership mux above still routes mem_la_*/mem_rdata to and
  // from the *debug* port. Completing a transfer for the CPU then hands it a
  // transaction it never issued, carrying the debug port's read data instead
  // of its own instruction fetch -- picorv32 retires that as an instruction,
  // and the program is gone. Observed as the PC collapsing from the
  // heartbeat loop to ~0 within 2.6 us of a DBG_RESUME issued before
  // BUS_UNLOCK, after which the counter never advances again.
  //
  // The gate is dbg_bus_active -- the debug unit's actual transfer -- and not
  // dbg_own, which is LOCK_ACTIVE for the whole lock (dbg_ctrl.sv). Gating on
  // dbg_own would stall the CPU for the entire lock and a STEP could never
  // retire anything, which is exactly the independence GRPR-DBG-025 needs.
  // dbg_bus_active is asserted only while a debug-sourced read or write is in
  // flight, so between those the mux above is back on the CPU's own signals
  // and a stepped or resumed CPU runs against real memory.
  //
  // Within a debug transfer the CPU simply waits, mid-transfer and with its
  // architectural state intact, exactly as it does under a freeze, and picks
  // up on the instruction it stalled on once the transfer completes -- the
  // same guarantee GRPR-DBG-043 already requires of a lock.

  assign cpu_mem_ready = mem_ready && !cpu_freeze && !dbg_bus_active;

  //--------------------------------------------------------------------------
  // Debug Unit
  //--------------------------------------------------------------------------

  dbg_ctrl #(
    .ADDR_WIDTH       (ADDR_WIDTH),
    .DATA_WIDTH       (DATA_WIDTH)
    
  ) u_dbg_ctrl (
    .clk              (HCLK),
    .rst_n            (HRESETn),

    .dbg_req_valid    (dbg_req_valid),
    .dbg_req_ready    (dbg_req_ready),
    .dbg_req_cmd      (dbg_req_cmd),
    .dbg_req_addr     (dbg_req_addr),
    .dbg_req_wdata    (dbg_req_wdata),
    .dbg_req_size     (dbg_req_size),
    .dbg_rsp_valid    (dbg_rsp_valid),
    .dbg_rsp_ready    (dbg_rsp_ready),
    .dbg_rsp_rdata    (dbg_rsp_rdata),
    .dbg_rsp_err      (dbg_rsp_err),

    .dbg_lock_active  (dbg_lock_active),

    .dbg_own          (dbg_own),
    .dbg_req          (dbg_req),
    .dbg_write        (dbg_write),
    .dbg_addr         (dbg_addr),
    .dbg_wdata        (dbg_wdata),
    .dbg_wstrb        (dbg_wstrb),
    .dbg_ready        (dbg_ready),
    .dbg_rdata        (dbg_rdata),
    .dbg_bus_error    (dbg_bus_error),

    .cpu_freeze       (cpu_freeze),
    .cpu_rst_req      (cpu_rst_req),

    .cpu_trace_valid  (cpu_trace_valid),
    .cpu_trace_data   (cpu_trace_data)
  );

  assign dbg_bus_error = dbg_own && bus_error;

  //--------------------------------------------------------------------------
  // Debug Memory Delay Registers
  //--------------------------------------------------------------------------
  
  // Register dbg write signals so that data falls in the data phase
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      dbg_wdata_r <= '0;
      dbg_addr_r  <= '0;
      dbg_wstrb_r <= '0;
    end else if (mem_la_write) begin
      dbg_wdata_r <= mem_la_wdata;
      dbg_addr_r  <= mem_la_addr;
      dbg_wstrb_r <= mem_la_wstrb;
    end
  end

  // A RAM read takes one clock cycle from the SRAM macro.
  // so ram_rdata is only valid the cycle *after* ram_read
  //
  // Only the first cycle of a debug RAM read counts as "just started" --
  // !dbg_ram_read_pending catches that one cycle; every later cycle of the
  // same still-outstanding read has dbg_ram_read_pending already set, so
  // this term drops out and dbg_ready is governed purely by ram_sel_r
  // below. Without that qualifier, dbg_req/mem_la_read staying asserted
  // for as long as dbg_ready stays low made this condition true every
  // cycle, permanently forcing dbg_ready to 0 -- a hang, not just a
  // one-cycle delay.

  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      dbg_ram_read_pending <= 1'b0;
    end else if (dbg_ram_read_start) begin
      dbg_ram_read_pending <= 1'b1;
    end else if (dbg_ram_read_pending && ram_sel_r) begin
      dbg_ram_read_pending <= 1'b0;
    end
  end

  assign dbg_ready = dbg_own && mem_ready &&
                      (dbg_ram_read_start ? 1'b0 :
                       dbg_ram_read_pending ? ram_sel_r : 1'b1);

  assign dbg_ram_read_start = !dbg_ram_read_pending && dbg_bus_active && mem_la_read && ram_sel;
  assign dbg_rdata = mem_rdata;

  //--------------------------------------------------------------------------
  // Bus Ownership Mux (GRPR-DBG-008)
  //--------------------------------------------------------------------------

  // Keyed on dbg_bus_active -- the debug unit's own transfer -- rather than on
  // dbg_own, which is LOCK_ACTIVE for the whole lock (dbg_ctrl.sv).
  //
  // A lock and a transfer are not the same window. STEP and DBG_RESUME both
  // clear cpu_freeze while the lock is still held (GRPR-DBG-025/-027), so the
  // CPU is meant to execute during part of a lock; keying the mux on dbg_own
  // pointed mem_la_* at a debug port that was not asking for anything, so the
  // CPU's own fetches and stores never reached memory at all while its
  // mem_ready said they had completed. picorv32 retired whatever mem_rdata
  // happened to hold, and the program was gone -- the PC collapsed from the
  // heartbeat loop to ~0 within 2.6 us of a DBG_RESUME issued before
  // BUS_UNLOCK, after which the counter never advanced again.
  //
  // Exclusivity is preserved by cpu_mem_ready below, which stalls the CPU for
  // as long as a debug transfer is in flight: the debug unit still wins every
  // cycle it actually wants the bus, and the CPU waits mid-transfer with its
  // architectural state intact, exactly as it does under a freeze.

  assign dbg_bus_active = dbg_own && dbg_req;

  assign mem_la_read  = dbg_bus_active ? !dbg_write : cpu_la_read;
  assign mem_la_write = dbg_bus_active ?  dbg_write : cpu_la_write;
  assign mem_la_addr  = dbg_bus_active ? dbg_addr  : cpu_la_addr;
  assign mem_la_wdata = dbg_bus_active ? dbg_wdata : cpu_la_wdata;
  assign mem_la_wstrb = dbg_bus_active ? dbg_wstrb : cpu_la_wstrb;

  //--------------------------------------------------------------------------
  // Bank Switch Logic
  //--------------------------------------------------------------------------
  //
  // The bank switch is detected a stage late, against bs_sel_r, so the address
  // and strobe have to come from the matching stage - mem_addr/mem_wstrb for
  // the CPU, the registered copies for debug. mem_valid is picorv32's own
  // transfer-in-progress flag and has no debug analogue, so the debug arm uses
  // its registered request instead.
  //
  // A debug-sourced bank switch is what makes the alternate boot path work
  // (GRPR-SOC-022): a host writes an image into RAM, flips the bank, and the
  // CPU restarts on it. That means the reset below fires on a debug write too,
  // which is intended - and it is also why GRPR-DBG-021 forbids this write
  // during a freeze-style lock, where resetting the CPU would destroy the very
  // state the freeze exists to preserve.

  assign bank_switch_write =
    bs_sel_r && (dbg_own  ? (dbg_wstrb_r[0] && dbg_addr_r == 32'h7fff_fffc)
                          : (mem_wstrb[0]   && mem_addr   == 32'h7fff_fffc));

  assign bank_switch_wdata = dbg_own ? dbg_wdata_r : mem_wdata;
  assign bank_switch_valid = dbg_own ? 1'b1 : mem_valid;

  // cpu_rst_req (GRPR-DBG-019, reset-style lock) holds the CPU in reset for
  // as long as the debug unit asserts it, unlike the bank-switch reset below,
  // which is a one-cycle pulse. Both share this flop because picorv32 has a
  // single resetn input; cpu_rst_req is checked first so a reset-style lock
  // taken mid-bank-switch still holds, and release only takes effect once
  // cpu_rst_req itself has been dropped by the debug unit.
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      bank_switch <= 0; // Start with ROM at address 0 on HRESETn
      cpu_rst_n <= '0;  // Reset CPU when HRESETn active
    end else if (cpu_rst_req) begin
      cpu_rst_n <= '0; // Debug unit reset-style lock: hold in reset
    end else if (bank_switch_valid && bank_switch_write) begin
      bank_switch <= bank_switch_wdata[0]; // Update bank switch value
      cpu_rst_n <= '0; // Reset CPU to boot from swapped RAM
    end else begin
      cpu_rst_n <= '1; // Release CPU reset
    end

  //--------------------------------------------------------------------------
  // Access Target MUX 
  //--------------------------------------------------------------------------

  always_comb begin
    rom_sel = '0;
    ram_sel = '0;
    bs_sel = '0;
    ahb_sel = '0;

    unique case (mem_la_addr[31:29])
      3'b000, 3'b001: begin // 0x0... ROM - Bank switch 0, RAM - Bank switch 1
        rom_sel = ~bank_switch;
        ram_sel = bank_switch;
      end
      3'b010: begin // 0x4... RAM - Bank switch 0, ROM - Bank switch 1
        rom_sel = bank_switch;
        ram_sel = ~bank_switch;
      end
      3'b011: begin // 0x6... Bank switch control register
        bs_sel = '1;
      end
      default: begin // 0x8... Otherwise AHB
        ahb_sel = '1;
      end 
    endcase
  end

  //--------------------------------------------------------------------------
  // RAM and ROM output ports 
  //--------------------------------------------------------------------------

  // ROM  
  assign rom_addr = mem_la_addr[2 +: ROM_ADDR_WIDTH];
  assign rom_read = rom_sel && mem_la_read;

  // RAM
  assign ram_addr  = mem_la_addr[2 +: RAM_ADDR_WIDTH];
  assign ram_wdata = mem_la_wdata;
  assign ram_wstrb = mem_la_wstrb;
  assign ram_write = ram_sel && mem_la_write;
  // Use lookahead signal for read so we don't need to delay mem_ready
  assign ram_read  = ram_sel && mem_la_read;

  //--------------------------------------------------------------------------
  // AHB output port
  //--------------------------------------------------------------------------

  // Ensure that HTRANS is only set when a read or write is triggered by the core.
  assign mem_la_req = mem_la_read || mem_la_write;

  // The AHB data phase outlasts its address phase whenever a slave stretches
  // Handle stalls and keep AHB pipelined otherwise
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      ahb_sel_r <= '0;
    end
    else if (ahb_sel && mem_la_req) begin
      ahb_sel_r <= '1;
    end
    else if (HREADY) begin
      ahb_sel_r <= '0;
    end
  end
  // convert native memory signals to AHB-Lite equivalents:
  // confusingly mem_la_wstrb is for read and write whereas mem_wstrb is only for write
  always_comb begin
    case (mem_la_wstrb)
      // byte access
      4'b0001: begin
        HSIZE = 3'b000;
        HADDR_byte = 0;
      end
      4'b0010: begin
        HSIZE = 3'b000;
        HADDR_byte = 1;
      end
      4'b0100: begin
        HSIZE = 3'b000;
        HADDR_byte = 2;
      end
      4'b1000: begin
        HSIZE = 3'b000;
        HADDR_byte = 3;
      end
      // half word access
      4'b0011: begin
        HSIZE = 3'b001;
        HADDR_byte = 0;
      end
      4'b1100: begin
        HSIZE = 3'b001;
        HADDR_byte = 2;
      end
      // word access
      default: begin
        HSIZE = 3'b010;
        HADDR_byte = 0;
      end
    endcase
  end
  
  // TODO - make sure the cpu_ss is fully protocol compliant
  assign HADDR      = {mem_la_addr[31:2], HADDR_byte[1:0]}; // Last 2 bits of mem_addr are always 0, so calculate from mem_wstrb
  assign HBURST     = '0;      // no burst transactions
  assign HMASTLOCK  = '0;      // no locked transactions (single master)
  assign HPROT      = 4'b0001; // this will default to data fetch (user access, non-bufferable, non-cacheable)
  assign HTRANS     = (ahb_sel && (mem_la_read || mem_la_write)) ? HTRANS_NONSEQ : HTRANS_IDLE;  // Non-Sequential or Idle only
  assign HWDATA     = dbg_own ? dbg_wdata_r : mem_wdata;
  assign HWRITE     = mem_la_write;
  
  //--------------------------------------------------------------------------
  // Response Logic
  //--------------------------------------------------------------------------

  // Register for next cycle (prevents circular logic)
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      ram_sel_r <= '0;
      bs_sel_r  <= '0;
    end else begin
      ram_sel_r <= ram_sel && mem_la_req;
      bs_sel_r  <= bs_sel  && mem_la_req;
    end
  end

  always_comb begin
    mem_rdata = rom_rdata;
    mem_ready = 1'b1; // Single cycle reads for ROM/RAM/BS
    bus_error = 1'b0; // No bus errors for ROM/RAM/BS access
    if (ram_sel_r) begin
      mem_rdata = ram_rdata;
    end else if (bs_sel_r) begin
      mem_rdata = {31'b0, bank_switch};
    end else if (ahb_sel_r) begin
      mem_rdata = HRDATA;
      mem_ready = HREADY;
      // An AHB error response is two cycles, HREADY low then high. Take it on
      // the completing cycle only, so one failed transfer raises one IRQ.
      bus_error = HRESP && HREADY;
    end
  end

endmodule
