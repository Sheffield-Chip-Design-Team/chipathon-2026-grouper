// Storage array for ahb_ram: four gf180mcu_ocd_ip_sram__sram1024x8m8wm1
// macros, one per byte lane of a 32-bit word, or a behavioural equivalent.
//
// Timing is the macro's: everything is captured on the clock edge, and read
// data appears on ram_rdata during the following cycle. ahb_ram owns the AHB
// side of that -- see the MACRO_RAM branch there.
//
// CEN, GWEN and WEN are all active low on the macro.

module ram_ss #(
  parameter int ADDR_WIDTH = 10,
  parameter bit USE_MACRO_RAM = 1
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic [ADDR_WIDTH-1:0] ram_addr,
  input  logic                  ram_read,
  input  logic                  ram_write,
  input  logic [31:0]           ram_wdata,
  input  logic [3:0]            ram_wstrb,
  output logic [31:0]           ram_rdata
);

  localparam int MEM_WORDS = 2**ADDR_WIDTH;

  // 1 RAM per byte lane
  generate
    if (USE_MACRO_RAM) begin : gen_macro_ram
      for (genvar j = 0; j < 4; j++) begin : gen_sram
        sram1024x8_wrapper u_wrapper (
          .CLK  (clk),
          .CEN  (~(ram_read || ram_write)),
          .GWEN (~ram_write),
          // Active low, and per bit. A lane the strobe does not select holds
          // WEN all ones, which the macro reads as "no write" (its write_flag
          // is !(&WEN)) -- so an unselected lane is untouched even though GWEN
          // is asserted for the word.
          .WEN  ({8{~ram_wstrb[j]}}),
          .A    (ram_addr),
          .D    (ram_wdata[j*8 +: 8]),
          .Q    (ram_rdata[j*8 +: 8])
        );
      end
    end else begin : gen_ff_ram

      // Memory Array  
      logic [31:0] memory [0:MEM_WORDS-1];

      // Write Port
      always_ff @(posedge clk)
        if (ram_write)
          for (int i = 0; i < 4; i++)
            if (ram_wstrb[i])
              memory[ram_addr][i*8 +: 8] <= ram_wdata[i*8 +: 8];
    
      // Read Port
      always_ff @(posedge clk, negedge rst_n)
        if (~rst_n)
          ram_rdata <= '0;
        else if (ram_read)
          ram_rdata <= memory[ram_addr];
    end
  endgenerate

endmodule
