package gpio_ctrl_pkg;

  // ---- Register map ------------------------------------------------------
  // Decoded from HADDR[5:2] - 16 word slots in the 4 KiB window at
  // 0x0000_4000. Offsets 0x2C-0x3C are reserved: reads return 0, writes ERROR.

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

endpackage
