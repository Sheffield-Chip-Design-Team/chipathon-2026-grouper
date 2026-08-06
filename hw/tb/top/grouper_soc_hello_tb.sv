`ifndef DUMP_FILE
`define DUMP_FILE "dump.fst"
`endif

`ifndef TB_TIMEOUT_CYCLES
`define TB_TIMEOUT_CYCLES 20_000_000
`endif

module grouper_soc_hello_tb;
  timeunit 1ns/1ps;

  localparam int TX_BAUD_RATE = 19200;   // Baud rate of uart_tx
  localparam int RX_BAUD_RATE = 19200;   // Baud rate of uart_rx (useful for testing resync)

  // The firmware computes its baud divisor from a hardcoded core clock
  localparam int CLK_FREQ = 10_000_000;  // Frequency of the clock in Hz

  // Clock and reset
  logic clk;
  logic rst_n;

  // UART signals
  logic uart_tx;
  logic uart_rx;

  // UART events for monitoring the DUT's uart_tx output
  event uart_tx_sample;
  event uart_tx_invalid_start_bit;
  event uart_tx_invalid_stop_bit;
  event uart_tx_newline;
  byte  last_tx_byte;

  mailbox #(byte) uart_tx_mb = new();

  // Test Tasks ---------------------------------------------------------------------------------

  // Report which firmware is in the ROM.
  task report_firmware();
    int    fd;
    string id;

    fd = $fopen("fw_id.txt", "r");
    if (fd == 0) begin
      $display("TB_FIRMWARE: unknown (fw_id.txt not found - was build_fw.sh run?)");
      return;
    end
    void'($fgets(id, fd));
    $fclose(fd);
    if (id.len() > 1 && id[id.len()-1] == "\n") id = id.substr(0, id.len()-2);
    $display("TB_FIRMWARE: %s", id);
  endtask

  // UART Tasks ------------------------------------------------------------------------------

  // UART Driver (DUT.uart_rx)
  task uart_rx_send(input byte c);
    uart_rx = 0;
    #(1000ms/RX_BAUD_RATE);
    repeat (8) begin
      {c, uart_rx} = {1'b0, c};
      #(1000ms/RX_BAUD_RATE);
    end
    uart_rx = 1;
    #(1000ms/RX_BAUD_RATE);
  endtask

  // UART Monitor (DUT.uart_tx)
  task automatic uart_tx_recv(output byte value, output bit ok);
    value = 0;

    // Wait for start bit
    @(negedge uart_tx);
    #(500ms/TX_BAUD_RATE); // Wait half a bit period
    ->uart_tx_sample;
    if (uart_tx) ->uart_tx_invalid_start_bit;

    repeat (8) begin
      #(1000ms/TX_BAUD_RATE);
      ->uart_tx_sample;
      value = { uart_tx, value[7:1] };
    end

    #(1000ms/TX_BAUD_RATE);
    ->uart_tx_sample;
    ok = uart_tx;
    if (~uart_tx) ->uart_tx_invalid_stop_bit;
  endtask

  // DUT instantiation ------------------------------------------------------------------------

  // FIXME - instantiate grouper_soc_top
  
  digital_ss  DUT (
      .clk                       (clk),
      .rst_n                     (rst_n),

      .uart_tx                   (uart_tx),
      .uart_rx                   (uart_rx),

      .gpio_in                   ('0),
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
      .ext_ahb_m_if_HRDATA       ('0),
      .ext_ahb_m_if_HREADY       (1'b1),
      .ext_ahb_m_if_HRESP        (1'b0)
  );

  // Clock and Reset ------------------------------------------------------------------------

  initial begin
    clk = 1'b0;
    forever begin
      #(0.5s/(CLK_FREQ));
      clk = ~clk;
    end
  end

  task reset();
    rst_n   = 1'b0;
    #123ns;
    fork
      begin @(posedge clk) rst_n = 1'b1; end
    join
    @(posedge clk);
  endtask

  // Test ------------------------------------------------------------------------
  
  initial begin
    rst_n   = 1'b1; // Generate an initial falling edge
    #1ns;
    reset();
  end

  initial begin
    byte value;
    bit  ok;
    forever begin
      uart_tx_recv(value, ok);
      if (ok) begin
        last_tx_byte = value;
        $write("%c", value);
        uart_tx_mb.put(value);
        if (value == 8'h0a) ->uart_tx_newline;
      end
    end
  end

  initial begin
    uart_rx = 1'b1;

    @(uart_tx_newline);
    
    uart_rx_send("W");
    uart_rx_send("o");
    uart_rx_send("r");
    uart_rx_send("l");
    uart_rx_send("d");
    uart_rx_send("\n");
    
    @(uart_tx_newline);

    // send exit code.
    uart_rx_send("e");
    uart_rx_send("x");
    uart_rx_send("i");
    uart_rx_send("t");
    uart_rx_send("\n");

    // Send a break
    uart_rx = 0;
  end

  // Checks -----------------------------------------------------------------------
  
  // Report Framing errors to detect BAUD RATE mismatch between the DUT and the testbench.
  initial begin
    fork
      @(uart_tx_invalid_start_bit);
      @(uart_tx_invalid_stop_bit);
    join_any
    $display("TB_ERROR: uart_tx framing error - DUT baud rate does not match TX_BAUD_RATE (%0d). Check CLK_FREQ here against SYS_CLK_HZ in sw/src/uart/uart.h", TX_BAUD_RATE);
  end

  // Timeout and Dump ------------------------------------------------------------------------

  initial begin
    $dumpfile(`DUMP_FILE);
    $dumpvars();
    report_firmware();
    
    // Do the test ...

    repeat(`TB_TIMEOUT_CYCLES) @(posedge clk);
    $display("TB_TIMEOUT: gave up waiting for firmware to reach the exit sequence after %0d cycles", `TB_TIMEOUT_CYCLES);
    $finish;
  end

endmodule