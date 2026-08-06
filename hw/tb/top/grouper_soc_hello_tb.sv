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

  localparam int NUM_GPIO = 16;          // Must match grouper_soc_top

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

  // GPIO pad model ---------------------------------------------------------------------------

  logic [NUM_GPIO-1:0] gpio_in;
  logic [NUM_GPIO-1:0] gpio_out;
  logic [NUM_GPIO-1:0] gpio_oe;
  logic [NUM_GPIO-1:0] gpio_cs;
  logic [NUM_GPIO-1:0] gpio_sl;
  logic [NUM_GPIO-1:0] gpio_ie;
  logic [NUM_GPIO-1:0] gpio_pu;
  logic [NUM_GPIO-1:0] gpio_pd;

  // What the testbench drives onto a pad the DUT is not driving.
  logic [NUM_GPIO-1:0] gpio_drive = '0;

  // A minimal pad cell, enough to make the firmware self-checking: an output
  // loops back to its own input, so firmware can verify what it drove by
  // reading GPIO_IN, and a pad with its input buffer disabled reads 0 - the
  // behaviour ahb_gpio_ctrl relies on when it declines to mask GPIO_IN with
  // GPIO_IE. Pull-ups and pull-downs are not modelled.
  for (genvar i = 0; i < NUM_GPIO; i++) begin : gen_pad
    assign gpio_in[i] = !gpio_ie[i] ? 1'b0
                      :  gpio_oe[i] ? gpio_out[i]
                                    : gpio_drive[i];
  end

  // Drive one pad from the testbench side.
  task automatic gpio_drive_pin(input int pin, input bit value);
    gpio_drive[pin] = value;
  endtask

  // DUT instantiation ------------------------------------------------------------------------

  grouper_soc_top #(
    .NUM_GPIO                    (NUM_GPIO)
  ) DUT (
    .clk                       (clk),
    .async_rst_n               (rst_n),

    .uart_tx                   (uart_tx),
    .uart_rx                   (uart_rx),

    .gpio_in                   (gpio_in),
    .gpio_out                  (gpio_out),
    .gpio_oe                   (gpio_oe),
    .gpio_cs                   (gpio_cs),
    .gpio_sl                   (gpio_sl),
    .gpio_ie                   (gpio_ie),
    .gpio_pu                   (gpio_pu),
    .gpio_pd                   (gpio_pd)
  );

  // grouper_soc_top does not expose the external AHB master - it ties those
  // signals off internally, and this testbench never drove them.

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