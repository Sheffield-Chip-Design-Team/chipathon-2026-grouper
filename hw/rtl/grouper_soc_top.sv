module grouper_soc_top #(
  parameter int NUM_GPIO = 16
)(
  // Clock and Reset Interfaces
  input logic                  clk,         // system clock (from board-level oscillator)
  input logic                  async_rst_n, // Active low asynchronous reset (from push button)

  // UART Interface
  output logic                 uart_tx,     // UART Transmit  
  input  logic                 uart_rx,     // UART Receive

  // GPIO PAD Interface
  input  logic [NUM_GPIO-1:0]  gpio_in,     // GPIO Input value (from pad)
  output logic [NUM_GPIO-1:0]  gpio_out,    // GPIO Output value
  output logic [NUM_GPIO-1:0]  gpio_oe,     // GPIO Output enable
  output logic [NUM_GPIO-1:0]  gpio_cs,     // GPIO Input type  (0=CMOS, 1=Schmitt)
  output logic [NUM_GPIO-1:0]  gpio_sl,     // GPIO Slew rate   (0=fast, 1=slow)
  output logic [NUM_GPIO-1:0]  gpio_ie,     // GPIO Input enable
  output logic [NUM_GPIO-1:0]  gpio_pu,     // GPIO Pull-up
  output logic [NUM_GPIO-1:0]  gpio_pd      // GPIO Pull-down
);  
 
  // --- Internal Signals ----------------------------------------------------------------

  logic [NUM_GPIO-1:0] gpio_sync_en_n;   // 1 = bypass, 0 = synchronised
  logic [NUM_GPIO-1:0] gpio_in_sync;
  logic [NUM_GPIO-1:0] gpio_in_dig;

  logic                rst_n_sync;       // Reset synchronised to sysclk

  // --- Clock and Reset Control (CRG) ---------------------------------------------------




  // --- Reset re-synchronizer ------------------------------------------------------------

    sync #(
      .DEPTH       (2)
    ) u_rst_resync_sync (
      .clk         (clk),
      .rst_n       (1'b1),
      .data_i      (async_rst_n),
      .data_o      (rst_n_sync)
    );

  // --- IO synchroniser -----------------------------------------------------------------s
  //
  // (GRPR-GPIO-001).
  // Pad inputs are asynchronous board-level signals, so each one passes
  // through two flops before it reaches any logic - the GPIO input register
  // and the serial peripherals both see the synchronised value
  //
  // Bypassing is a deliberate CDC violation, offered for latency-sensitive or
  // already-synchronous signals; no metastability guarantee is made for a
  // bypassed pad.

  for (genvar i = 0; i < NUM_GPIO; i++) begin : gen_gpio_sync
    sync #(
      .DEPTH       (2)
    ) u_gpio_sync (
      .clk         (clk),
      .rst_n       (async_rst_n),
      .data_i      (gpio_in[i]),
      .data_o      (gpio_in_sync[i])
    );

    assign gpio_in_dig[i] = gpio_sync_en_n[i] ? gpio_in[i] : gpio_in_sync[i];
  end

  // --- Digital Subsystem -------------------------------------------------------------

  digital_ss #(
    .ADDR_WIDTH                (32),
    .DATA_WIDTH                (32),
    .NUM_GPIO                  (NUM_GPIO)
  ) u_grouper_soc_dig_ss (
    .clk                       (clk),
    .rst_n                     (rst_n_sync),

    .uart_tx                   (uart_tx),
    .uart_rx                   (uart_rx),

    .gpio_in                   (gpio_in_dig),
    .gpio_out                  (gpio_out),
    .gpio_oe                   (gpio_oe),

    .gpio_cs                   (gpio_cs),
    .gpio_sl                   (gpio_sl),
    .gpio_ie                   (gpio_ie),
    .gpio_pu                   (gpio_pu),
    .gpio_pd                   (gpio_pd),

    .gpio_sync_en_n            (gpio_sync_en_n),

    .ext_ahb_m_if_HADDR        (),
    .ext_ahb_m_if_HBURST       (),
    .ext_ahb_m_if_HMASTLOCK    (),
    .ext_ahb_m_if_HPROT        (),
    .ext_ahb_m_if_HSIZE        (),
    .ext_ahb_m_if_HTRANS       (),
    .ext_ahb_m_if_HWDATA       (),
    .ext_ahb_m_if_HWRITE       (),
    .ext_ahb_m_if_HRDATA       ('0),
    .ext_ahb_m_if_HREADY       (1'b1),
    .ext_ahb_m_if_HRESP        (1'b0)
  );

endmodule
