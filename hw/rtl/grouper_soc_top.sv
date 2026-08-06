module grouper_soc_top (
  input logic   sysclk,
  
  input logic   reset_btn_n,

  // UART Interface
  output logic  uart_tx,
  input  logic  uart_rx
);

  // Reset resynchronizer


  // IO synchronisers


  // Clock and Reset Control (CRG) 


  // Digital SoC Logic

  digital_ss #(
    .ADDR_WIDTH                (32),
    .DATA_WIDTH                (32)
  ) u_grouper_soc_dig_ss (
    .clk                       (sysclk),
    .rst_n                     (reset_btn_n),

    .uart_tx                   (uart_tx),
    .uart_rx                   (uart_rx),

    .gpio_in                   (),
    .gpio_out                  (),
    .gpio_oe                   (),

    .gpio_cs                   (),
    .gpio_sl                   (),
    .gpio_ie                   (),
    .gpio_pu                   (),
    .gpio_pd                   (),

    .gpio_sync_en_n            (),

    .ext_ahb_m_if_HADDR        (),
    .ext_ahb_m_if_HBURST       (),
    .ext_ahb_m_if_HMASTLOCK    (),
    .ext_ahb_m_if_HPROT        (),
    .ext_ahb_m_if_HSIZE        (),
    .ext_ahb_m_if_HTRANS       (),
    .ext_ahb_m_if_HWDATA       (),
    .ext_ahb_m_if_HWRITE       (),
    .ext_ahb_m_if_HRDATA       (),
    .ext_ahb_m_if_HREADY       (),
    .ext_ahb_m_if_HRESP        ()
  );



endmodule
