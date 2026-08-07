// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    // Defaults are the slot 1x1 pad counts; chip_top always overrides these
    // from slot_defines.svh.
    parameter int unsigned NUM_INPUT_PADS = 12,
    parameter int unsigned NUM_BIDIR_PADS = 40,
    // GrouperSoC GPIO count. Must be <= NUM_BIDIR_PADS - 1 
    // (one bidir pad is spent on uart_tx).
    parameter int unsigned NUM_GPIO       = 16
)(
    input  wire clk,                            // clock
    input  wire rst_n,                          // reset (active low)

    input  wire [NUM_INPUT_PADS-1:0] input_in,  // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,  // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,  // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,  // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out, // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,  // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,  // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,  // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,  // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,  // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd   // Pull-down
);

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html
    //
    // Pad map (slot 1x1: 12 input pads, 40 bidir pads)
    //
    //   input_PAD[0]              uart_rx
    //   input_PAD[NUM_INPUT-1:1]  unused
    //   bidir_PAD[NUM_GPIO-1:0]   gpio[NUM_GPIO-1:0]  (SoC drives out/oe/cs/sl/ie/pu/pd)
    //   bidir_PAD[NUM_GPIO]       uart_tx             (output only)
    //   bidir_PAD[..:NUM_GPIO+1]  unused, driven low

    localparam int unsigned UART_TX_PAD  = NUM_GPIO;         // bidir index of uart_tx
    localparam int unsigned NUM_USED_BID = NUM_GPIO + 1;     // gpio + uart_tx

    // --- SoC <-> pad signals ------------------------------------------------

    wire [NUM_GPIO-1:0] gpio_in;
    wire [NUM_GPIO-1:0] gpio_out;
    wire [NUM_GPIO-1:0] gpio_oe;
    wire [NUM_GPIO-1:0] gpio_cs;
    wire [NUM_GPIO-1:0] gpio_sl;
    wire [NUM_GPIO-1:0] gpio_ie;
    wire [NUM_GPIO-1:0] gpio_pu;
    wire [NUM_GPIO-1:0] gpio_pd;

    wire                uart_tx;
    wire                uart_rx;

    // --- Input-only pads ----------------------------------------------------

    // Disable pull-up and pull-down for input
    assign input_pu = '0;
    assign input_pd = '0;

    assign uart_rx  = input_in[0];

    // --- Bidirectional pads -------------------------------------------------

    // GPIO pads: every pad control comes from the SoC's GPIO controller.
    assign bidir_out[NUM_GPIO-1:0] = gpio_out;
    assign bidir_oe [NUM_GPIO-1:0] = gpio_oe;
    assign bidir_cs [NUM_GPIO-1:0] = gpio_cs;
    assign bidir_sl [NUM_GPIO-1:0] = gpio_sl;
    assign bidir_ie [NUM_GPIO-1:0] = gpio_ie;
    assign bidir_pu [NUM_GPIO-1:0] = gpio_pu;
    assign bidir_pd [NUM_GPIO-1:0] = gpio_pd;

    assign gpio_in = bidir_in[NUM_GPIO-1:0];

    // uart_tx: permanent output, input buffer off.
    assign bidir_out[UART_TX_PAD] = uart_tx;
    assign bidir_oe [UART_TX_PAD] = 1'b1;
    assign bidir_cs [UART_TX_PAD] = 1'b0;
    assign bidir_sl [UART_TX_PAD] = 1'b0;
    assign bidir_ie [UART_TX_PAD] = 1'b0;
    assign bidir_pu [UART_TX_PAD] = 1'b0;
    assign bidir_pd [UART_TX_PAD] = 1'b0;

    // Spare pads: driven low so they never float, input buffer off.
    if (NUM_BIDIR_PADS > NUM_USED_BID) begin : gen_spare_bidir
        assign bidir_out[NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
        assign bidir_oe [NUM_BIDIR_PADS-1:NUM_USED_BID] = '1;
        assign bidir_cs [NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
        assign bidir_sl [NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
        assign bidir_ie [NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
        assign bidir_pu [NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
        assign bidir_pd [NUM_BIDIR_PADS-1:NUM_USED_BID] = '0;
    end

    // Tie off the pad inputs nothing reads.
    logic _unused;
    assign _unused = &{1'b0,
                       input_in[NUM_INPUT_PADS-1:1],
                       bidir_in[NUM_BIDIR_PADS-1:NUM_GPIO]};

    // --- GrouperSoC ---------------------------------------------------------

    grouper_soc_top #(
        .NUM_GPIO       (NUM_GPIO)
    ) u_grouper_soc_top (
        .clk            (clk),
        .async_rst_n    (rst_n),

        .uart_tx        (uart_tx),
        .uart_rx        (uart_rx),

        .gpio_in        (gpio_in),
        .gpio_out       (gpio_out),
        .gpio_oe        (gpio_oe),
        .gpio_cs        (gpio_cs),
        .gpio_sl        (gpio_sl),
        .gpio_ie        (gpio_ie),
        .gpio_pu        (gpio_pu),
        .gpio_pd        (gpio_pd)
    );

endmodule

`default_nettype wire
