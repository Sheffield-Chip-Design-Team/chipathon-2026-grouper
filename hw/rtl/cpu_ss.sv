module cpu_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int ROM_ADDR_WIDTH = 8,
  parameter int RAM_ADDR_WIDTH = 10,
  parameter int NUM_IRQ = 1,
  parameter bit ENABLE_TRACE = 1'b0    // sim-only instruction trace, consumed by ahb_debug
) (
  
  // Clock and Reset
  input logic HCLK,
  input logic HRESETn,

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
  // AHB Master signals
  output logic [ADDR_WIDTH-1:0] HADDR,
  output logic [2:0]            HBURST,
  output logic                  HMASTLOCK,
  output logic [3:0]            HPROT,
  output logic [2:0]            HSIZE,
  output logic [1:0]            HTRANS,
  output logic [DATA_WIDTH-1:0] HWDATA,
  output logic                  HWRITE,

  // AHB Slave Signals
  input logic [DATA_WIDTH-1:0]  HRDATA,
  input logic                   HREADY,
  input logic                   HRESP,

  // Interrupts
  input logic [NUM_IRQ-1:0]     irq,

  // Instruction trace (all zeroes unless ENABLE_TRACE)
  output logic                  trace_valid,
  output logic [35:0]           trace_data
);

  import ahb3lite_pkg::*;

  logic         cpu_rst_n;      // Reset used by CPU
  logic         bus_error;      // AHB bus error

  // picorv32 outputs this design deliberately does not consume: traps are
  // routed back as IRQ 1 by the CPU itself, instruction/data fetches take the
  // same path here, the low two address bits are always zero (HADDR_byte is
  // derived from the strobes instead), and nothing acknowledges
  // end-of-interrupt.
  /* verilator lint_off UNUSEDSIGNAL */
  logic         trap;           // CPU trap signal
  logic         mem_instr;
  logic [31:0]  eoi;
  /* verilator lint_on UNUSEDSIGNAL */

  // Drives the RAM write port - see the look-ahead discussion further down.
  logic [31:0]  mem_la_wdata;

  // Memory interface
  logic         mem_valid;
  logic         mem_ready;
  logic [31:0]  mem_addr;
  logic [31:0]  mem_wdata;
  // Only [0] is read, by the bank switch decode below - the memories and the
  // AHB bridge take their strobes from the look-ahead group instead.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ 3:0]  mem_wstrb;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0]  mem_rdata;

  // Look-Ahead Interface
  logic         mem_la_req;     // the CPU is actually asking for something
  logic         mem_la_read;
  logic         mem_la_write;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0]  mem_la_addr;    // [1:0] always zero - word-aligned by picorv32
  /* verilator lint_on UNUSEDSIGNAL */
  logic [ 3:0]  mem_la_wstrb;

  // IRQ Interface
  logic [31:0]  irq_int;

  // Trace Interface
  logic         cpu_trace_valid;
  logic [35:0]  cpu_trace_data;

  // Address decode
  logic rom_sel;
  logic ram_sel;
  logic bs_sel;
  logic ahb_sel;
  logic ram_sel_r;
  logic bs_sel_r;
  logic ahb_sel_r;

  // AHB decode 
  logic [1:0] HADDR_byte;

  // Hidden register for bank switch
  logic bank_switch;
  logic bank_switch_write;

  // IRQ 0-2 Can also be triggered by the CPU internally
  // IRQ 0 - Timer Interrupt
  // IRQ 1 - EBREAK/ECALL or Illegal Instruction
  // IRQ 2 - BUS Error (Unalign Memory Access) + Used for invalid memory address
  assign irq_int = {{(29-NUM_IRQ){1'b0}}, irq, bus_error, 2'b0};

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
    .mem_ready    (mem_ready),
    .mem_addr     (mem_addr),
    .mem_wdata    (mem_wdata),
    .mem_wstrb    (mem_wstrb),
    .mem_rdata    (mem_rdata),

	  // Look-Ahead Interface
    .mem_la_read  (mem_la_read),
    .mem_la_write (mem_la_write),
    .mem_la_addr  (mem_la_addr),
    .mem_la_wdata (mem_la_wdata),
    .mem_la_wstrb (mem_la_wstrb),

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

  // convert native memory signals to AHB-Lite equivalents:
  assign bank_switch_write = bs_sel_r && mem_wstrb[0] == 1'b1 && mem_addr == 32'h7fff_fffc;

  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      bank_switch <= 0; // Start with ROM at address 0 on HRESETn
      cpu_rst_n <= '0;  // Reset CPU when HRESETn active
    end else if (mem_valid && bank_switch_write) begin // Use mem_valid to detect CPU reset
      bank_switch <= mem_wdata[0]; // Update bank switch value
      cpu_rst_n <= '0; // Reset CPU to boot from swapped RAM
    end else begin
      cpu_rst_n <= '1; // Release CPU reset
    end

  // Select output interfaces based on address decode
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

  // mem_la_addr only means anything while the CPU is actually asking for
  // something. Between accesses picorv32 leaves an ALU operand on it -
  // "mem_la_addr = (mem_do_prefetch || mem_do_rinst) ? next_pc :
  // {reg_op1[31:2], 2'b00}" - so the decode above is free-running over data.
  // That is harmless for rom_read/ram_read, which are already qualified by
  // mem_la_read, but the registered selects below drive mem_ready and
  // bus_error, so they have to see a real request or the CPU takes a fault
  // over an address it never issued.
  //
  // This is exactly what a value in flight through the bootloader's tx_uint()
  // did: shifting 0xff800093 left a byte at a time put 0x8000_9300 on
  // mem_la_addr, which decodes as AHB, and the resulting phantom data phase
  // sampled HRESP off an idle bus - a bus error IRQ for a transfer that never
  // happened. HTRANS was already gated this way and correctly stayed IDLE.
  assign mem_la_req = mem_la_read || mem_la_write;

  // Register for next cycle (prevents circular logic)
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      ram_sel_r <= '0;
      bs_sel_r  <= '0;
    end else begin
      ram_sel_r <= ram_sel && mem_la_req;
      bs_sel_r  <= bs_sel  && mem_la_req;
    end

  // The AHB data phase outlasts its address phase whenever a slave stretches
  // HREADY - ahb_uart does it on a busy FIFO, and every error response is two
  // cycles - so this is a transfer-outstanding flag rather than a delayed
  // copy of the select. Setting it takes priority so back-to-back transfers
  // stay pipelined.
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn)
      ahb_sel_r <= '0;
    else if (ahb_sel && mem_la_req)
      ahb_sel_r <= '1;
    else if (HREADY)
      ahb_sel_r <= '0;

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
  
  assign rom_addr = mem_la_addr[2 +: ROM_ADDR_WIDTH];
  assign rom_read = rom_sel && mem_la_read;

  // The RAM port is driven entirely from picorv32's look-ahead group. That
  // pairing is load bearing, not stylistic: ram_addr comes from mem_la_addr,
  // so the write enable and the write data have to come from the same stage.
  //
  // Qualifying the write with mem_wstrb instead - which belongs to mem_addr,
  // a stage later - lets the two disagree, and the write then lands at
  // whatever address the look-ahead has already moved on to. The bank switch
  // made that fatal: storing to BANK_SWITCH_ADDR resets the CPU, mem_la_addr
  // jumps to PROGADDR_RESET, ram_sel goes high because RAM has just been
  // swapped to zero, and mem_wstrb is still holding 4'hf from the store that
  // caused all this. The result was a write of the bank switch value over the
  // reset vector, one cycle before the CPU fetched it - so the freshly booted
  // image always trapped on its first instruction.
  //
  // mem_la_write cannot do that: it is gated by resetn and only asserts in
  // the cycle that issues the address (picorv32.v, "assign mem_la_write =
  // resetn && !mem_state && mem_do_wdata"). picorv32 builds mem_wstrb out of
  // it the same way - "mem_wstrb <= mem_la_wstrb & {4{mem_la_write}}".
  //
  // This also closes the wider version of the same hole: on a multi-cycle
  // transfer mem_wstrb stays asserted for the whole transfer while
  // mem_la_addr is free to move, so an AHB write stalled by HREADY could
  // previously scribble into RAM.
  assign ram_addr  = mem_la_addr[2 +: RAM_ADDR_WIDTH];
  assign ram_wdata = mem_la_wdata;
  assign ram_wstrb = mem_la_wstrb;
  assign ram_write = ram_sel && mem_la_write;
  // Use lookahead signal for read so we don't need to delay mem_ready
  assign ram_read  = ram_sel && mem_la_read;
  
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
  assign HWDATA     = mem_wdata;
  assign HWRITE     = mem_la_write;
endmodule
