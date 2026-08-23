// Generic simulation model of gf180mcu_ocd_ip_sram__sram1024x8m8wm1.
//
// Same module name and port list as the vendor model in
//   ip/gf180mcu_ocd_ip_sram/cells/gf180mcu_ocd_ip_sram__sram1024x8m8wm1/
// (copied here as gf180mcu_ocd_ip_sram_1024x8m8wm1_gl_model.v) so it is a
// drop-in replacement: pick one or the other with the `generic` / `gate`
// targets of sram1024x8.core, never both.
//
// Behaviour only - no `specify` block, no notifiers, no delays, no timescale
// dependence. Everything happens on posedge CLK, so it elaborates under both
// Icarus and Verilator. Use the vendor model (the `gate` target) when the
// point of the run is timing checks or $sdf_annotate back-annotation.
//
// Macro semantics, all active low:
//   CEN  = 0        chip enabled; when 1 the array and Q both hold
//   GWEN = 0        this access is a write, GWEN = 1 makes it a read
//   WEN[i] = 0      bit i of D is written (per-bit mask, not per-byte)
//   A               word address, 1024 x 8 b
//   Q               registered read data, valid the cycle after the read
//
// A write with WEN = 8'hff enables no bits and is therefore not an access at
// all - the array holds and so does Q. Q is likewise held through a write:
// the macro has no write-through path, so a read must be a separate access.

// The file is deliberately not named after the module: the name belongs to the
// vendor macro, and two files claiming it (here and under ip/) would be one
// grep away from confusion.
/* verilator lint_off DECLFILENAME */
module gf180mcu_ocd_ip_sram__sram1024x8m8wm1 (
`ifdef USE_POWER_PINS
  inout  wire        VDD,
  inout  wire        VSS,
`endif
  input  wire        CLK,
  input  wire        CEN,   // Chip Enable Negative
  input  wire        GWEN,  // Global Write Enable Negative
  input  wire [7:0]  WEN,   // Write Enable Negative (per bit)
  input  wire [9:0]  A,
  input  wire [7:0]  D,
  output wire [7:0]  Q
);

  localparam DEPTH = 1024;

  reg [7:0] mem [0:DEPTH-1];
  reg [7:0] q_reg;

  assign Q = q_reg;

  wire enable = ~CEN;
  wire write  = enable & ~GWEN & ~(&WEN);
  wire read   = enable &  GWEN;

  // Merge the written bits into the current contents; WEN masks the old
  // value, ~WEN masks the new one.
  wire [7:0] wdata = (mem[A] & WEN) | (D & ~WEN);

  always @(posedge CLK) begin
    if (enable && (^A === 1'bx)) begin
      // An X in the address means we cannot tell which word was hit. Corrupt
      // the read data rather than the array, and say so - silently reading
      // mem[0] would hide a real bug in the address path.
      $display("%0t %m: X on A during an enabled access (CEN=%b GWEN=%b A=%b)",
               $time, CEN, GWEN, A);
      if (read) q_reg <= 8'bx;
    end
    else if (write) mem[A] <= wdata;
    else if (read)  q_reg  <= mem[A];
  end

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) mem[i] = 8'h00;
    q_reg = 8'h00;
  end

endmodule
