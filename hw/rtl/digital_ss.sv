module digital_ss #(
  parameter int                      ADDR_WIDTH = 32,
  parameter int                      DATA_WIDTH = 32,
  parameter int                      ROM_ADDR_WIDTH = 8,
  parameter int                      RAM_ADDR_WIDTH = 10,
  parameter int                      EXT_ADDR_WIDTH = 8,
  parameter int                      EXT_DATA_WIDTH = 8,
  parameter int                      NUM_GPIO   = 16
)(
  // Clock and Reset
  input logic                        clk,                     // System clock
  input logic                        rst_n,                   // System reset (active low)

  // UART Interface
  output logic                       uart_tx,                 // UART Transmit
  input  logic                       uart_rx,                 // UART Receive

  // GPIO PAD Interface
  input  logic [NUM_GPIO-1:0]        gpio_in,                 // GPIO Input value
  output logic [NUM_GPIO-1:0]        gpio_out,                // GPIO Output value
  output logic [NUM_GPIO-1:0]        gpio_oe,                 // GPIO Output enable
  output logic [NUM_GPIO-1:0]        gpio_cs,                 // GPIO Input type           (0=CMOS, 1=Schmitt)
  output logic [NUM_GPIO-1:0]        gpio_sl,                 // GPIO Slew rate            (0=fast, 1=slow)
  output logic [NUM_GPIO-1:0]        gpio_ie,                 // GPIO Input enable
  output logic [NUM_GPIO-1:0]        gpio_pu,                 // GPIO Pull-up
  output logic [NUM_GPIO-1:0]        gpio_pd,                 // GPIO Pull-down 

  output logic [NUM_GPIO-1:0]        gpio_sync_en_n,          // GPIO Synchronizer enable (0=sync, 1=async)

  // External AHB Master Interface
  output logic [EXT_ADDR_WIDTH-1:0]  ext_ahb_m_if_HADDR,      // External AHB3 lite Address bus
  output logic [2:0]                 ext_ahb_m_if_HBURST,     // External AHB3 lite Burst type
  output logic                       ext_ahb_m_if_HMASTLOCK,  // External AHB3 lite Master lock
  output logic [3:0]                 ext_ahb_m_if_HPROT,      // External AHB3 lite Protection type
  output logic [2:0]                 ext_ahb_m_if_HSIZE,      // External AHB3 lite Size type
  output logic [1:0]                 ext_ahb_m_if_HTRANS,     // External AHB3 lite Transfer type
  output logic [EXT_DATA_WIDTH-1:0]  ext_ahb_m_if_HWDATA,     // External AHB3 lite Write data
  output logic                       ext_ahb_m_if_HWRITE,     // External AHB3 lite Write signal
  input  logic [EXT_DATA_WIDTH-1:0]  ext_ahb_m_if_HRDATA,     // External AHB3 lite Read data
  input  logic                       ext_ahb_m_if_HREADY,     // External AHB3 lite Ready signal
  input  logic                       ext_ahb_m_if_HRESP       // External AHB3 lite Response signal
);

  // --- Internal Signals ------------------------------------------------------------

  // AHB from CPU to Periph SS
  logic [ADDR_WIDTH-1:0]      cpu_ss_ahb_s_if_HADDR;
  logic [2:0]                 cpu_ss_ahb_s_if_HBURST;
  logic                       cpu_ss_ahb_s_if_HMASTLOCK;
  logic [3:0]                 cpu_ss_ahb_s_if_HPROT;
  logic [2:0]                 cpu_ss_ahb_s_if_HSIZE;
  logic [1:0]                 cpu_ss_ahb_s_if_HTRANS;
  logic [DATA_WIDTH-1:0]      cpu_ss_ahb_s_if_HWDATA;
  logic                       cpu_ss_ahb_s_if_HWRITE;
  logic [DATA_WIDTH-1:0]      cpu_ss_ahb_s_if_HRDATA;
  logic                       cpu_ss_ahb_s_if_HREADY;
  logic                       cpu_ss_ahb_s_if_HRESP;

  // ROM Interface
  logic [ROM_ADDR_WIDTH-1:0]  rom_addr;
  logic                       rom_read;
  logic [DATA_WIDTH-1:0]      rom_rdata;

  // RAM Interface
  logic [RAM_ADDR_WIDTH-1:0]  ram_addr;
  logic                       ram_read;
  logic                       ram_write;
  logic [DATA_WIDTH-1:0]      ram_wdata;
  logic [3:0]                 ram_wstrb;
  logic [DATA_WIDTH-1:0]      ram_rdata;

  // Interrupts
  logic                       uart_rx_irq;
  logic                       uart_rx_error_irq;

  // CPU instruction trace (all zeroes unless CPU_TRACE)
  logic                       cpu_trace_valid;
  logic [35:0]                cpu_trace_data;

  // Debug Unit lock-active indication (GRPR-DBG-044), passed through to
  // io_ss's pad-3 output-enable gate (GRPR-GPIO-016).
  logic                       dbg_lock_active;

  // Debug port between cpu_ss (slave) and the SPI Slave transport (master,
  // inside periph_ss). GRPR-DBG-042.
  logic                       dbg_req_valid;
  logic                       dbg_req_ready;
  logic [3:0]                 dbg_req_cmd;
  logic [ADDR_WIDTH-1:0]      dbg_req_addr;
  logic [DATA_WIDTH-1:0]      dbg_req_wdata;
  logic [1:0]                 dbg_req_size;
  logic                       dbg_rsp_valid;
  logic                       dbg_rsp_ready;
  logic [DATA_WIDTH-1:0]      dbg_rsp_rdata;
  logic                       dbg_rsp_err;

  // --- CPU Subsystem ------------------------------------------------------------
  // Picorv32 Subsytem with AHB-lite master interface and Direct Memory interface 
  // with bank switch logic
  
  cpu_ss #(
    .ADDR_WIDTH     (ADDR_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .ROM_ADDR_WIDTH (ROM_ADDR_WIDTH),
    .RAM_ADDR_WIDTH (RAM_ADDR_WIDTH),
    .ENABLE_TRACE   (1'b1),
    .NUM_IRQ        (2)
  ) u_cpu_ss (
    .HCLK       (clk),
    .HRESETn    (rst_n),

    // ROM Interface
    .rom_addr   (rom_addr),
    .rom_read   (rom_read),
    .rom_rdata  (rom_rdata),

    // RAM Interface
    .ram_addr   (ram_addr),
    .ram_read   (ram_read),
    .ram_write  (ram_write),
    .ram_wdata  (ram_wdata),
    .ram_wstrb  (ram_wstrb),
    .ram_rdata  (ram_rdata),

    // AHB Master Interface
    .HADDR      (cpu_ss_ahb_s_if_HADDR),
    .HBURST     (cpu_ss_ahb_s_if_HBURST),
    .HMASTLOCK  (cpu_ss_ahb_s_if_HMASTLOCK),
    .HPROT      (cpu_ss_ahb_s_if_HPROT),
    .HSIZE      (cpu_ss_ahb_s_if_HSIZE),
    .HTRANS     (cpu_ss_ahb_s_if_HTRANS),
    .HWDATA     (cpu_ss_ahb_s_if_HWDATA),
    .HWRITE     (cpu_ss_ahb_s_if_HWRITE),
    .HRDATA     (cpu_ss_ahb_s_if_HRDATA),
    .HREADY     (cpu_ss_ahb_s_if_HREADY),
    .HRESP      (cpu_ss_ahb_s_if_HRESP),

    // Debug port (GRPR-DBG-042), connected through to the SPI Slave
    // transport inside periph_ss below. With no SS/SCK/MOSI activity on the
    // wire and CTRL.LOCK_EN closed at reset (GRPR-SOC-029), dbg_req_valid
    // stays low on its own and the mux inside cpu_ss remains a wire, so
    // nothing here needs a separate tie-off any more.
    .dbg_req_valid   (dbg_req_valid),
    .dbg_req_ready   (dbg_req_ready),
    .dbg_req_cmd     (dbg_req_cmd),
    .dbg_req_addr    (dbg_req_addr),
    .dbg_req_wdata   (dbg_req_wdata),
    .dbg_req_size    (dbg_req_size),
    .dbg_rsp_valid   (dbg_rsp_valid),
    .dbg_rsp_ready   (dbg_rsp_ready),
    .dbg_rsp_rdata   (dbg_rsp_rdata),
    .dbg_rsp_err     (dbg_rsp_err),

    .dbg_lock_active (dbg_lock_active),

    .irq        ({
      uart_rx_error_irq,
      uart_rx_irq
    }),

    // Instruction trace (all zeroes unless ENABLE_TRACE)
    .trace_valid (cpu_trace_valid),
    .trace_data  (cpu_trace_data)
  );

  // --- Memory Subsystems --------------------------------------------------------
  // RAM and ROM directly connected to the CPU subsytem - no AHB interconnect

  rom_ss #(
    .ADDR_WIDTH (ROM_ADDR_WIDTH)
  ) u_rom_ss (
    .clk        (clk),
    .rom_addr   (rom_addr),
    .rom_read   (rom_read),
    .rom_rdata  (rom_rdata)
  );

  ram_ss #(
    .ADDR_WIDTH (RAM_ADDR_WIDTH)
  ) u_ram_ss (
    .clk        (clk),
    .ram_addr   (ram_addr),
    .ram_read   (ram_read),
    .ram_write  (ram_write),
    .ram_wdata  (ram_wdata),
    .ram_wstrb  (ram_wstrb),
    .ram_rdata  (ram_rdata)
  );

  // --- Peripheral Subsystem --------------------------------------------------------
  // Interconnect + AHBlite Peripheral blocks (UART, GPIO, SPI M/S, QSPI)

  periph_ss #(
    .ADDR_WIDTH          (ADDR_WIDTH),
    .DATA_WIDTH          (DATA_WIDTH),
    .NUM_GPIO            (NUM_GPIO)
  ) u_periph_ss (
    .HCLK                (clk),
    .HRESETn             (rst_n),

    .HADDR               (cpu_ss_ahb_s_if_HADDR),
    .HBURST              (cpu_ss_ahb_s_if_HBURST),
    .HMASTLOCK           (cpu_ss_ahb_s_if_HMASTLOCK),
    .HPROT               (cpu_ss_ahb_s_if_HPROT),
    .HSIZE               (cpu_ss_ahb_s_if_HSIZE),
    .HTRANS              (cpu_ss_ahb_s_if_HTRANS),
    .HWDATA              (cpu_ss_ahb_s_if_HWDATA),
    .HWRITE              (cpu_ss_ahb_s_if_HWRITE),
    .HRDATA              (cpu_ss_ahb_s_if_HRDATA),
    .HREADY              (cpu_ss_ahb_s_if_HREADY),
    .HRESP               (cpu_ss_ahb_s_if_HRESP),

    .uart_rx_irq         (uart_rx_irq),
    .uart_rx_error_irq   (uart_rx_error_irq),
 
    .uart_tx             (uart_tx),
    .uart_rx             (uart_rx),
    
    // GPIO pin control interface
    .gpio_in             (gpio_in),
    .gpio_out            (gpio_out),
    .gpio_oe             (gpio_oe),
    .gpio_cs             (gpio_cs),
    .gpio_sl             (gpio_sl),
    .gpio_ie             (gpio_ie),
    .gpio_pu             (gpio_pu),
    .gpio_pd             (gpio_pd),
    .gpio_sync_en_n      (gpio_sync_en_n),

    // CPU instruction trace
    .trace_valid         (cpu_trace_valid),
    .trace_data          (cpu_trace_data),

    // Debug Unit lock-active indication, passed through to io_ss.
    .dbg_lock_active     (dbg_lock_active),

    // Debug port, terminated at the SPI Slave transport inside periph_ss.
    .dbg_req_valid       (dbg_req_valid),
    .dbg_req_ready       (dbg_req_ready),
    .dbg_req_cmd         (dbg_req_cmd),
    .dbg_req_addr        (dbg_req_addr),
    .dbg_req_wdata       (dbg_req_wdata),
    .dbg_req_size        (dbg_req_size),
    .dbg_rsp_valid       (dbg_rsp_valid),
    .dbg_rsp_ready       (dbg_rsp_ready),
    .dbg_rsp_rdata       (dbg_rsp_rdata),
    .dbg_rsp_err         (dbg_rsp_err),

    // External AHB master interface
    .ext_HADDR           (ext_ahb_m_if_HADDR),
    .ext_HBURST          (ext_ahb_m_if_HBURST),
    .ext_HMASTLOCK       (ext_ahb_m_if_HMASTLOCK),
    .ext_HPROT           (ext_ahb_m_if_HPROT),
    .ext_HSIZE           (ext_ahb_m_if_HSIZE),
    .ext_HTRANS          (ext_ahb_m_if_HTRANS),
    .ext_HWDATA          (ext_ahb_m_if_HWDATA),
    .ext_HWRITE          (ext_ahb_m_if_HWRITE),
    .ext_HRDATA          (ext_ahb_m_if_HRDATA),
    .ext_HREADY          (ext_ahb_m_if_HREADY),
    .ext_HRESP           (ext_ahb_m_if_HRESP)
  );

endmodule
