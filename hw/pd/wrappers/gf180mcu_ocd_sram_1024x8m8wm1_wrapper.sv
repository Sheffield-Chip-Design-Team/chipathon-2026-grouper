// Wrapper for gf180mcu_ocd_ip_sram__sram1024x8m8wm1
//
// The macro instantiated here comes from whichever fileset the sram1024x8.core
// target selected: _rtl_model.v (`generic`) or _gl_model.v (`gate`). Ports are
// identical either way.

/* verilator lint_off DECLFILENAME */
module sram1024x8_wrapper (
	input  wire 			CLK,
	input  wire 			CEN,	// Chip Enable
	input  wire 			GWEN,	// Global Write Enable
	input  wire [7:0] WEN,	// Write Enable
	input  wire [9:0] A,
	input  wire [7:0] D,
	output wire [7:0] Q
);

// `ifdef USE_POWER_PINS
// 	wire VDD;
// 	wire VSS;
// `endif

	gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_sram_macro (
// `ifdef USE_POWER_PINS
// 		.VDD 	(VDD),
// 		.VSS 	(VSS),
// `endif
		.CLK 	(CLK),
		.CEN 	(CEN),
		.GWEN	(GWEN),
		.WEN 	(WEN),
		.A   	(A),
		.D   	(D),
		.Q   	(Q)
	);

endmodule
