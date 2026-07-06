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

  // TODO instantiate the IBEX

  ibex_top #(
    .PMPEnable                       (1'b0),
    .PMPGranularity                  (0),
    .PMPNumRegions                   (4),
    .MHPMCounterNum                  (0),
    .MHPMCounterWidth                (40),
    .]                               (ibex_pkg::PmpCfgRst),
    .]                               (ibex_pkg::PmpAddrRst),
    .PMPRstMsecCfg                   (ibex_pkg::PmpMseccfgRst),
    .RV32E                           (1'b1),
    .RV32M                           (RV32MSlow),
    .RV32B                           (RV32BNone),
    .RV32ZC                          (RV32ZcaZcbZcmp),
    .RegFile                         (RegFileFF),
    .BranchTargetALU                 (1'b0),
    .WritebackStage                  (1'b0),
    .ICache                          (1'b0),
    .ICacheECC                       (1'b0),
    .BranchPredictor                 (1'b0),
    .DbgTriggerEn                    (1'b0),
    .DbgHwBreakNum                   (1),
    .SecureIbex                      (1'b0),
    .LockstepOffset                  (1),
    .MemECC                          (SecureIbex),
    .MemDataWidth                    (MemECC?32+7:32),
    .ICacheScramble                  (1'b0),
    .ICacheScrNumPrinceRoundsHalf    (2),
    .ICacheTweakInfection            (SecureIbex),
    .RndCnstLfsrSeed                 (RndCnstLfsrSeedDefault),
    .RndCnstLfsrPerm                 (RndCnstLfsrPermDefault),
    .DmBaseAddr                      (32'h1A110000),
    .DmAddrMask                      (32'h00000FFF),
    .DmHaltAddr                      (32'h1A110800),
    .DmExceptionAddr                 (32'h1A110808),
    // Default seed and nonce for scrambling
    .RndCnstIbexKey                  (RndCnstIbexKeyDefault),
    .RndCnstIbexNonce                (RndCnstIbexNonceDefault),
    // mvendorid: encoding of manufacturer/provider
    // 0 indicates this field is not implemented. Ibex implementers may wish to set their
    // own JEDEC ID here.
    .CsrMvendorId                    (32'b0),
    // mimpid: encoding of processor implementation version
    // 0 indicates this field is not implemented. Ibex implementers may wish to indicate an
    // RTL/netlist version here using their own unique encoding (e.g. 32 bits of the git hash of the
    // implemented commit).
    .CsrMimpId                       (32'b0)
) u_ibex_top (
    // Clock and Reset
    .clk_i                           (clk_i),
    .rst_ni                          (rst_ni),
    // enable all clock gates for testing
    .test_en_i                       (test_en_i),
    .ram_cfg_icache_tag_i            (ram_cfg_icache_tag_i),
    .ram_cfg_rsp_icache_tag_o        (ram_cfg_rsp_icache_tag_o),
    .ram_cfg_icache_data_i           (ram_cfg_icache_data_i),
    .ram_cfg_rsp_icache_data_o       (ram_cfg_rsp_icache_data_o),
    .hart_id_i                       (hart_id_i),
    .boot_addr_i                     (boot_addr_i),
    // Instruction memory interface
    .instr_req_o                     (instr_req_o),
    .instr_gnt_i                     (instr_gnt_i),
    .instr_rvalid_i                  (instr_rvalid_i),
    .instr_addr_o                    (instr_addr_o),
    .instr_rdata_i                   (instr_rdata_i),
    .instr_rdata_intg_i              (instr_rdata_intg_i),
    .instr_err_i                     (instr_err_i),
    // Data memory interface
    .data_req_o                      (data_req_o),
    .data_gnt_i                      (data_gnt_i),
    .data_rvalid_i                   (data_rvalid_i),
    .data_we_o                       (data_we_o),
    .data_be_o                       (data_be_o),
    .data_addr_o                     (data_addr_o),
    .data_wdata_o                    (data_wdata_o),
    .data_wdata_intg_o               (data_wdata_intg_o),
    .data_rdata_i                    (data_rdata_i),
    .data_rdata_intg_i               (data_rdata_intg_i),
    .data_err_i                      (data_err_i),
    // Interrupt inputs
    .irq_software_i                  (irq_software_i),
    .irq_timer_i                     (irq_timer_i),
    .irq_external_i                  (irq_external_i),
    .irq_fast_i                      (irq_fast_i),
    // non-maskeable interrupt
    .irq_nm_i                        (irq_nm_i),
    // Scrambling Interface
    .scramble_key_valid_i            (scramble_key_valid_i),
    .scramble_key_i                  (scramble_key_i),
    .scramble_nonce_i                (scramble_nonce_i),
    .scramble_req_o                  (scramble_req_o),
    // Debug Interface
    .debug_req_i                     (debug_req_i),
    .crash_dump_o                    (crash_dump_o),
    .double_fault_seen_o             (double_fault_seen_o),
    // CPU Control Signals
    .fetch_enable_i                  (fetch_enable_i),
    .alert_minor_o                   (alert_minor_o),
    .alert_major_internal_o          (alert_major_internal_o),
    .alert_major_bus_o               (alert_major_bus_o),
    .core_sleep_o                    (core_sleep_o),
    // DFT bypass controls
    .scan_rst_ni                     (scan_rst_ni),
    // Lockstep signals
    .lockstep_cmp_en_o               (lockstep_cmp_en_o),
    // Shadow core data interface outputs
    .data_req_shadow_o               (data_req_shadow_o),
    .data_we_shadow_o                (data_we_shadow_o),
    .data_be_shadow_o                (data_be_shadow_o),
    .data_addr_shadow_o              (data_addr_shadow_o),
    .data_wdata_shadow_o             (data_wdata_shadow_o),
    .data_wdata_intg_shadow_o        (data_wdata_intg_shadow_o),
    // Shadow core instruction interface outputs
    .instr_req_shadow_o              (instr_req_shadow_o),
    .instr_addr_shadow_o             (instr_addr_shadow_o)
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
