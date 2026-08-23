// Simulation model of gf180mcu_ocd_ip_sram__sram1024x8m8wm1, for the cocotb
// flow. Selected by MACRO_RAM, which is what makes ahb_ram build ram_ss and
// four of these instead of a behavioural array.
//
// Neither model the vendor ships works here:
//
//   *.v            Behavioural core wrapped in a specify block. Verilator
//                  rejects it outright ("Can't find definition of variable:
//                  'Tdly'" -- a specparam used as a delay outside specify),
//                  and under an event simulator it samples CEN, GWEN and A
//                  100ps AFTER the clock edge. Zero-delay RTL has already
//                  driven the next cycle's values by then, so the last access
//                  of a burst is silently dropped: the macro reports
//                  read_flag=1 with the right address on the cycle it is
//                  issued, then never latches Q because CEN has gone away at
//                  the sampling instant. It needs real hold time to behave,
//                  which only gate-level simulation has.
//   *__blackbox.v  Ports only, no behaviour. That is the one synthesis wants
//                  (librelane/classic/config.yaml points `vh` at it) and it
//                  is useless in simulation.
//
// This is the same memory with everything sampled AT the clock edge. Ports,
// polarities and read timing match the vendor model:
//
//   CEN   active low chip enable; nothing happens while it is high
//   GWEN  active low write enable -- high selects a read
//   WEN   active low per-bit write mask; all ones means "no write" even when
//         GWEN is asserted, which is how ahb_ram's byte strobes deselect a lane
//   Q     the addressed byte, valid throughout the cycle AFTER the access, and
//         held until the next read. A write does not disturb it.
//
// Deliberately no timing checks. The hold requirements the vendor model
// enforces (tch ~1.6ns typ on CEN, tah ~0.7ns on A, and up to 3.0ns at the
// slow corner) are a place-and-route obligation, checked by STA against the
// Liberty files -- not something RTL simulation can say anything useful about.
//
// Contents come up zeroed, as in the vendor model. Define SRAM_INIT_X to start
// them at x instead, which turns "firmware read RAM it never wrote" from a
// silent zero into visible x propagation.

module gf180mcu_ocd_ip_sram__sram1024x8m8wm1 (
`ifdef USE_POWER_PINS
  inout  wire       VDD,
  inout  wire       VSS,
`endif
  input  wire       CLK,
  input  wire       CEN,   // Chip Enable Negative
  input  wire       GWEN,  // Global Write Enable Negative
  input  wire [7:0] WEN,   // Write Enable Negative, per bit
  input  wire [9:0] A,
  input  wire [7:0] D,
  output reg  [7:0] Q
);

  reg [7:0] mem [0:1023];

  wire write_op = ~CEN & ~GWEN & ~(&WEN);
  wire read_op  = ~CEN &  GWEN;

  integer i;
  initial begin
    Q = 8'h00;
    for (i = 0; i < 1024; i = i + 1)
`ifdef SRAM_INIT_X
      mem[i] = 8'hxx;
`else
      mem[i] = 8'h00;
`endif
  end

  always @(posedge CLK) begin
    if (write_op)
      mem[A] <= (mem[A] & WEN) | (D & ~WEN);
    else if (read_op)
      Q <= mem[A];
  end

endmodule
