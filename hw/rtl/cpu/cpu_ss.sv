module cpu_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int NUM_IRQ = 1
) (
  input logic HCLK,
  input logic HRESETn,

  // AHB Master Interface
  // Don't use interfaces at hierarchy boundaries for better conversion to verilog
  
  // Master Signals
  output logic [ADDR_WIDTH-1:0] HADDR,
  output logic [2:0]            HBURST,
  output logic                  HMASTLOCK,
  output logic [3:0]            HPROT,
  output logic [2:0]            HSIZE,
  output logic [1:0]            HTRANS,
  output logic [DATA_WIDTH-1:0] HWDATA,
  output logic                  HWRITE,

  // Slave Signals
  input logic [DATA_WIDTH-1:0]  HRDATA,
  input logic                   HREADY,
  input logic                   HRESP,

  // Interrupts
  input logic [NUM_IRQ-1:0]     irq
);

  import ahb3lite_pkg::*;

  logic         bus_error;

  logic         trap;

  // Memory interface
  logic         mem_valid;
  logic         mem_instr;
  logic         mem_ready;
  logic [31:0]  mem_addr;
  logic [31:0]  mem_wdata;
  logic [ 3:0]  mem_wstrb;
  logic [31:0]  mem_rdata;

  // Look-Ahead Interface
  logic         mem_la_read;
  logic         mem_la_write;
  logic [31:0]  mem_la_addr;
  logic [31:0]  mem_la_wdata;
  logic [ 3:0]  mem_la_wstrb;

  // IRQ Interface
  logic [31:0]  irq_int;
  logic [31:0]  eoi;

  // IRQ 0-2 Can also be triggered by the CPU internally
  // IRQ 0 - Timer Interrupt
  // IRQ 1 - EBREAK/ECALL or Illegal Instruction
  // IRQ 2 - BUS Error (Unalign Memory Access) + Used for invalid memory address
  assign irq_int = {{(29-NUM_IRQ){1'b0}}, irq, bus_error, 2'b0};

  picorv32 #(
	  .ENABLE_COUNTERS      (1),
	  .ENABLE_COUNTERS64    (1),
	  .ENABLE_REGS_16_31    (1),
	  .ENABLE_REGS_DUALPORT (1),
	  .LATCHED_MEM_RDATA    (0),
	  .TWO_STAGE_SHIFT      (1),
	  .BARREL_SHIFTER       (0),
	  .TWO_CYCLE_COMPARE    (0),
	  .TWO_CYCLE_ALU        (0),
	  .COMPRESSED_ISA       (0),
	  .CATCH_MISALIGN       (1),
	  .CATCH_ILLINSN        (1),
	  .ENABLE_PCPI          (0),
	  .ENABLE_MUL           (1),
	  .ENABLE_FAST_MUL      (0),
	  .ENABLE_DIV           (1),
	  .ENABLE_IRQ           (1),
	  .ENABLE_IRQ_QREGS     (1),
	  .ENABLE_IRQ_TIMER     (1),
	  .ENABLE_TRACE         (0),
	  .REGS_INIT_ZERO       (0),
	  .MASKED_IRQ           (32'h 0000_0000),
	  .LATCHED_IRQ          (32'h ffff_ffff),
	  .PROGADDR_RESET       (32'h 0000_0000),
	  .PROGADDR_IRQ         (32'h 0000_0010),
	  .STACKADDR            (32'h ffff_ffff)
  ) u_cpu (
    .clk          (HCLK),
    .resetn       (HRESETn),
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
    .trace_valid  (),
    .trace_data   ()
  );

  // convert native memory signals to AHB-Lite equivalents:

  logic [1:0] HADDR_byte;

  // confusingly mem_la_wstrb is for read and write whereas mem_wstrb is only for write
  always_comb
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

  assign HADDR      = {mem_la_addr[31:2], HADDR_byte[1:0]}; // Last 2 bits of mem_addr are always 0, so calculate from mem_wstrb
  assign HBURST     = '0;  // no burst transactions
  assign HMASTLOCK  = '0;  // no locked transactions
  assign HPROT      = 4'b0001; // this will default to data fetch (user access, non-bufferable, non-cacheable)
  assign HTRANS     = (mem_la_read || mem_la_write) ? HTRANS_BUSY : HTRANS_IDLE;  // Non-Sequential or Idle only
  assign HWDATA     = mem_wdata;
  assign HWRITE     = mem_la_write;

  assign mem_rdata  = HRDATA;
  assign mem_ready  = HREADY;

  // TODO: Handle HRESP, maybe fire an IRQ?
  assign bus_error  = HRESP;

endmodule
