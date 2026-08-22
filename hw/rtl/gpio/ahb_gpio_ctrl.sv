// GPIO Controller with external MUX support
//
// Specification: docs/hardware/design/blocks/GPIO Mux.md
// Directed tests: hw/tb/gpio/test_gpio.py (port names must match)

module ahb_gpio_ctrl #(
  parameter int ADDR_WIDTH = 32,
  parameter int DATA_WIDTH = 32,
  parameter int NUM_GPIO   = 16
) (
  input logic                   HCLK,
  input logic                   HRESETn,

  // AHB Slave Interface

  // Master Signals

  /* verilator lint_off UNUSEDSIGNAL */
  input logic [ADDR_WIDTH-1:0]  HADDR,
  input logic [2:0]             HBURST,
  input logic                   HMASTLOCK,
  input logic [3:0]             HPROT,
  input logic [2:0]             HSIZE,
  input logic [1:0]             HTRANS,
  input logic [DATA_WIDTH-1:0]  HWDATA,
  input logic                   HWRITE,
  /* verilator lint_on UNUSEDSIGNAL */

  // Slave Signals
  output logic [DATA_WIDTH-1:0] HRDATA,
  output logic                  HREADYOUT,
  output logic                  HRESP,

  // Decoder Signals
  input logic                   HREADYIN,
  input logic                   HSEL,

  // Input Signal Interface
  input  logic [NUM_GPIO-1:0]   mux_io_i,
  output logic [NUM_GPIO-1:0]   mux_io_o,     
  output logic [NUM_GPIO-1:0]   mux_alt_sel,     

  // PAD interface
  output logic [NUM_GPIO-1:0]   gpio_oe,          // GPIO_OE
  output logic [NUM_GPIO-1:0]   gpio_sync_en_n,   // GPIO_SYNC_EN_N
  output logic [NUM_GPIO-1:0]   gpio_ie,          // GPIO_IE
  output logic [NUM_GPIO-1:0]   gpio_pu,          // GPIO_PU
  output logic [NUM_GPIO-1:0]   gpio_pd,          // GPIO_PD
  output logic [NUM_GPIO-1:0]   gpio_cs,          // GPIO_CS
  output logic [NUM_GPIO-1:0]   gpio_sl           // GPIO_SL
);

  import ahb3lite_pkg::*;
  
  // ---- Register Block ------------------------------------------------------
  // Decoded from HADDR[5:2] - 16 word slots in the 4 KiB window at
  // 0x8000_4000. Offsets 0x2C-0x3C are reserved: reads return 0, writes ERROR.
  
  localparam bit [3:0] REG_OUT        = 4'h0;  // 0x00 RW  output data
  localparam bit [3:0] REG_IN         = 4'h1;  // 0x04 RO  live pad value
  localparam bit [3:0] REG_OE         = 4'h2;  // 0x08 RW  output enable
  localparam bit [3:0] REG_ALTSEL     = 4'h3;  // 0x0C RW  alternate function select
  localparam bit [3:0] REG_RO_MASK    = 4'h4;  // 0x10 RW  read-only pad mask
  localparam bit [3:0] REG_SYNC_EN_N  = 4'h5;  // 0x14 RW  synchroniser bypass
  localparam bit [3:0] REG_IE         = 4'h6;  // 0x18 RW  input enable
  localparam bit [3:0] REG_PU         = 4'h7;  // 0x1C RW  pull-up
  localparam bit [3:0] REG_PD         = 4'h8;  // 0x20 RW  pull-down
  localparam bit [3:0] REG_CS         = 4'h9;  // 0x24 RW  input type
  localparam bit [3:0] REG_SL         = 4'hA;  // 0x28 RW  slew rate
  localparam bit [3:0] REG_LAST_VALID = REG_SL;

  localparam int NUM_BYTES = DATA_WIDTH / 8;

  // Internal Signals
  logic [NUM_GPIO-1:0] wdata;
  logic [NUM_GPIO-1:0] wmask;

  //  Register Fields 
  logic [NUM_GPIO-1:0] out_r;         // GPIO_OUT
  logic [NUM_GPIO-1:0] oe_r;          // GPIO_OE
  logic [NUM_GPIO-1:0] alt_sel_r;     // MUX_ALT_SEL
  logic [NUM_GPIO-1:0] ro_mask_r;     // READ-ONLY_MASK
  logic [NUM_GPIO-1:0] sync_en_n_r;   // SYNCHRONIZER_ENABLE_N
  logic [NUM_GPIO-1:0] ie_r;          // GPIO_IE
  logic [NUM_GPIO-1:0] pu_r;          // GPIO_PU
  logic [NUM_GPIO-1:0] pd_r;          // GPIO_PD
  logic [NUM_GPIO-1:0] cs_r;          // GPIO_CS
  logic [NUM_GPIO-1:0] sl_r;          // GPIO_SL

  // AHB control signals 
  logic                 access;
  logic                 read_enable;
  logic                 read_enable_r;
  logic                 write_enable;
  logic [3:0]           word_address;
  logic [3:0]           word_address_r;
  logic [NUM_BYTES-1:0] byte_select;
  logic [NUM_BYTES-1:0] byte_select_r;

  logic                  invalid_access;
  logic                  reserved_access;
  logic                  error_req;
  logic                  err_phase2;
  logic [DATA_WIDTH-1:0] bit_enable;      // byte_select_r expanded to bits

  // ---- Helper Functions ------------------------------------------------------

  // Merge the selected byte lanes over a register's current value, so a byte
  // or halfword write leaves the other lanes alone.
  function automatic logic [NUM_GPIO-1:0] merge(input logic [NUM_GPIO-1:0] old_val);
    return (wdata & wmask) | (old_val & ~wmask);
  endfunction

  // Mask a register's current value with the read-only mask, so that any bits
  // that are read-only remain unchanged.
  function automatic logic [NUM_GPIO-1:0] merge_ro(input logic [NUM_GPIO-1:0] old_val);
    return (merge(old_val) & ~ro_mask_r) | (old_val & ro_mask_r);
  endfunction

  // ---- AHB Control Logic ------------------------------------------------------

  // Generate the control signals in the address phase
  assign access       = HREADYIN && HSEL && (HTRANS != HTRANS_IDLE);
  assign read_enable  = access && ~HWRITE;

  assign word_address = access ? HADDR[5:2] : '0;
  assign byte_select  = access ? generate_byte_select_32(HSIZE, HADDR[1:0]) : '0;

  // Delay the control signals into the data phase.
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      write_enable    <= '0;
      read_enable_r   <= '0;
      word_address_r  <= '0;
      byte_select_r   <= '0;
    end else if (HREADYOUT) begin
      write_enable    <= access && HWRITE;
      read_enable_r   <= read_enable;
      word_address_r  <= word_address;
      byte_select_r   <= byte_select;
    end
  end

  // Byte lanes not selected by this transfer cannot be written, so they
  // cannot violate the read-only mask either.
  always_comb begin
    for (int b = 0; b < NUM_BYTES; b++)
      bit_enable[b*8 +: 8] = {8{byte_select_r[b]}};
  end

  // Write data and its bit-granular mask, both narrowed to the implemented pads.
  assign wdata = HWDATA[NUM_GPIO-1:0];
  assign wmask = bit_enable[NUM_GPIO-1:0];

  // Invalid access 
  assign reserved_access = (word_address_r > REG_LAST_VALID);

  always_comb begin
    invalid_access = 1'b0;
    // Reads never error - every pad stays readable at all times
    // (GRPR-GPIO-004), and reserved offsets read back zero.
    if (write_enable) begin
      if (reserved_access)                invalid_access = 1'b1;
      else if (word_address_r == REG_IN)  invalid_access = 1'b1;  // read-only
    end
  end

  // ---- Write Logic ------------------------------------------------------
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) begin
      out_r       <= '0;
      oe_r        <= '0;
      alt_sel_r   <= '0;
      ro_mask_r   <= '0;
      sync_en_n_r <= '0;
      ie_r        <= '0;
      pu_r        <= '0;
      pd_r        <= '0;
      cs_r        <= '0;
      sl_r        <= '0;
    end else if (write_enable && !invalid_access) begin
      case (word_address_r)
        REG_OUT:       out_r       <= merge_ro(out_r);
        REG_OE:        oe_r        <= merge(oe_r);
        REG_ALTSEL:    alt_sel_r   <= merge(alt_sel_r);
        REG_RO_MASK:   ro_mask_r   <= merge(ro_mask_r);
        REG_SYNC_EN_N: sync_en_n_r <= merge(sync_en_n_r);
        REG_IE:        ie_r        <= merge(ie_r);
        REG_PU:        pu_r        <= merge(pu_r);
        REG_PD:        pd_r        <= merge(pd_r);
        REG_CS:        cs_r        <= merge(cs_r);
        REG_SL:        sl_r        <= merge(sl_r);
        default: begin end   // REG_IN and reserved - rejected above
      endcase
    end
  end

  // ---- Read Logic ------------------------------------------------------
  always_comb begin
    if (!read_enable_r)
      // Zero when not reading is not required, but it keeps waveforms honest.
      HRDATA = '0;
    else
      case (word_address_r)
        REG_OUT:       HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, out_r};
        REG_IN:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, mux_io_i};
        REG_OE:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, oe_r};
        REG_ALTSEL:    HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, alt_sel_r};
        REG_RO_MASK:   HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, ro_mask_r};
        REG_SYNC_EN_N: HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, sync_en_n_r};
        REG_IE:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, ie_r};
        REG_PU:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, pu_r};
        REG_PD:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, pd_r};
        REG_CS:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, cs_r};
        REG_SL:        HRDATA = {{(DATA_WIDTH-NUM_GPIO){1'b0}}, sl_r};
        default:       HRDATA = '0;   // reserved - reads zero, does not error
      endcase
  end

  // ---- Transfer response -------------------------------------------------

  // AMBA 3 AHB-Lite two-cycle ERROR (GRPR-GPIO-010): HRESP high for two
  // cycles, HREADYOUT low on the first and high on the second, so the master
  // gets a cycle to cancel the transfer already in its address phase. 

  assign error_req = write_enable && invalid_access;
  
  always_ff @(posedge HCLK, negedge HRESETn) begin
    if (~HRESETn) err_phase2 <= '0;
    else          err_phase2 <= error_req && !err_phase2;
  end
  
  assign HREADYOUT = !(error_req && !err_phase2);
  assign HRESP     = error_req || err_phase2;

  //  --- Pad outputs ---------------------------------------------------------
  assign mux_io_o       = out_r;
  assign mux_alt_sel    = alt_sel_r;
  assign gpio_oe        = oe_r;
  assign gpio_sync_en_n = sync_en_n_r;
  assign gpio_ie        = ie_r;
  assign gpio_pu        = pu_r;
  assign gpio_pd        = pd_r;
  assign gpio_cs        = cs_r;
  assign gpio_sl        = sl_r;

endmodule
