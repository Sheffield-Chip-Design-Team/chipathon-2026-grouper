module cpu_ss #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int ROM_ADDR_WIDTH = 8,
  parameter int RAM_ADDR_WIDTH = 10,
  parameter int NUM_IRQ = 1
) (
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

  // import ahb3lite_pkg::*;
  `include "ahb3lite.svh"

  logic         cpu_rst_n; // Reset used by CPU

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
	  .ENABLE_REGS_16_31    (0),
	  .ENABLE_REGS_DUALPORT (1),
	  .LATCHED_MEM_RDATA    (0),
	  .TWO_STAGE_SHIFT      (1),
	  .BARREL_SHIFTER       (0),
	  .TWO_CYCLE_COMPARE    (0),
	  .TWO_CYCLE_ALU        (0),
	  .COMPRESSED_ISA       (1),
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
    .trace_valid  (),
    .trace_data   ()
  );

  // Address decode
  logic rom_sel;
  logic ram_sel;
  logic bs_sel;
  logic ahb_sel;
  logic ram_sel_r;
  logic bs_sel_r;
  logic ahb_sel_r;

  // Hidden register for bank switch
  logic bank_switch;
  logic bank_switch_write;

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

  // Register for next cycle (prevents circular logic)
  always_ff @(posedge HCLK, negedge HRESETn)
    if (~HRESETn) begin
      ram_sel_r <= '0;
      bs_sel_r  <= '0;
      ahb_sel_r <= '0;
    end else begin
      ram_sel_r <= ram_sel;
      bs_sel_r  <= bs_sel;
      ahb_sel_r <= ahb_sel;
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
      bus_error = HRESP;
    end
  end
  
  assign rom_addr = mem_la_addr[2 +: ROM_ADDR_WIDTH];
  assign rom_read = rom_sel && mem_la_read;

  assign ram_addr  = mem_la_addr[2 +: RAM_ADDR_WIDTH];
  assign ram_wdata = mem_wdata;
  assign ram_wstrb = mem_wstrb;
  // Still need a cycle for mem_ready, so use mem_wstrb for ram_write
  // Should help improve timing
  assign ram_write = ram_sel && (mem_wstrb != '0);
  // Use lookahead signal for read so we don't need to delay mem_ready
  assign ram_read  = ram_sel && mem_la_read;
  
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
  assign HTRANS     = (ahb_sel && (mem_la_read || mem_la_write)) ? HTRANS_NONSEQ : HTRANS_IDLE;  // Non-Sequential or Idle only
  assign HWDATA     = mem_wdata;
  assign HWRITE     = mem_la_write;

endmodule
