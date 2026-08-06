// For connecting two ahb3lite interfaces togeter
// Useful for putting interfaces into an array

module ahb_conn (
  ahb3lite_intf.master ahb_m,
  ahb3lite_intf.slave ahb_s
);

  assign ahb_m.HADDR      = ahb_s.HADDR;
  assign ahb_m.HBURST     = ahb_s.HBURST;
  assign ahb_m.HMASTLOCK  = ahb_s.HMASTLOCK;
  assign ahb_m.HPROT      = ahb_s.HPROT;
  assign ahb_m.HSIZE      = ahb_s.HSIZE;
  assign ahb_m.HTRANS     = ahb_s.HTRANS;
  assign ahb_m.HWDATA     = ahb_s.HWDATA;
  assign ahb_m.HWRITE     = ahb_s.HWRITE;
  
  assign ahb_s.HRDATA     = ahb_m.HRDATA;
  assign ahb_s.HREADYOUT  = ahb_m.HREADYOUT;
  assign ahb_s.HRESP      = ahb_m.HRESP;
  
  assign ahb_m.HREADYIN   = ahb_s.HREADYIN;
  assign ahb_m.HSEL       = ahb_s.HSEL;

endmodule
