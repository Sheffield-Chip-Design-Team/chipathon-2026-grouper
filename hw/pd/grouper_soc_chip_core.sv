// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0
//
// grouper_soc_chip_core - the hardened macro, and the top level of the
// LibreLane classic flow (librelane/classic/config.yaml).
//
// It wraps grouper_soc_top in a flat pad-facing port list: every pad-facing
// port is a single signal, so the macro's boundary is one net per pad line
// rather than a bus. The GPIO pad map is the concatenations in the instance
// below - pad index N is gpio[N] - and there is nothing else to it.
//
// Only GPIO carries the pad-control interface, because only GPIO is
// configurable at run time. uart_rx and uart_tx leave here as plain signals;
// mapping them onto pads - pulls off for uart_rx, oe=1 / ie=0 for uart_tx - is
// chip_top's job, along with every spare pad in the slot. That keeps this port
// list independent of which slot the padring is built for, and it is why the
// pad budget is fixed here rather than parameterised (a flat port list cannot
// be).
//
// Port names are <function>_<pad kind>_<signal>, with the index carried in the
// function where the function has more than one pad:
//
//   gpio_0_bidir_{in,out,oe,cs,sl,ie,pu,pd} .. gpio_15_*  bidir pads 0-15

`default_nettype none

module grouper_soc_chip_core (
    input  wire clk,               // clock
    input  wire rst_n,             // reset (active low)

    // --- UART ---------------------------------------------------------------
    input  wire uart_rx,           // from an input-only pad
    output wire uart_tx,           // to a bidir pad held as an output

    // --- Bidirectional pads -------------------------------------------------
    //   *_in  Input value                
    //   *_ie  Input enable
    //   *_out Output value               
    //  *_pu Pull-up
    //   *_oe  Output enable              
    //   *_pd Pull-down
    //   *_cs  Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    //   *_sl  Slew rate  (0=fast, 1=slow)

    input  wire gpio_0_bidir_in,    // gpio_0 PAD
    output wire gpio_0_bidir_out,
    output wire gpio_0_bidir_oe,
    output wire gpio_0_bidir_cs,
    output wire gpio_0_bidir_sl,
    output wire gpio_0_bidir_ie,
    output wire gpio_0_bidir_pu,
    output wire gpio_0_bidir_pd,

    input  wire gpio_1_bidir_in,    // gpio_1 PAD
    output wire gpio_1_bidir_out,
    output wire gpio_1_bidir_oe,
    output wire gpio_1_bidir_cs,
    output wire gpio_1_bidir_sl,
    output wire gpio_1_bidir_ie,
    output wire gpio_1_bidir_pu,
    output wire gpio_1_bidir_pd,

    input  wire gpio_2_bidir_in,    // gpio_2 PAD
    output wire gpio_2_bidir_out,
    output wire gpio_2_bidir_oe,
    output wire gpio_2_bidir_cs,
    output wire gpio_2_bidir_sl,
    output wire gpio_2_bidir_ie,
    output wire gpio_2_bidir_pu,
    output wire gpio_2_bidir_pd,

    input  wire gpio_3_bidir_in,    // gpio_3 PAD
    output wire gpio_3_bidir_out,
    output wire gpio_3_bidir_oe,
    output wire gpio_3_bidir_cs,
    output wire gpio_3_bidir_sl,
    output wire gpio_3_bidir_ie,
    output wire gpio_3_bidir_pu,
    output wire gpio_3_bidir_pd,

    input  wire gpio_4_bidir_in,    // gpio_4 PAD
    output wire gpio_4_bidir_out,
    output wire gpio_4_bidir_oe,
    output wire gpio_4_bidir_cs,
    output wire gpio_4_bidir_sl,
    output wire gpio_4_bidir_ie,
    output wire gpio_4_bidir_pu,
    output wire gpio_4_bidir_pd,

    input  wire gpio_5_bidir_in,    // gpio_5 PAD
    output wire gpio_5_bidir_out,
    output wire gpio_5_bidir_oe,
    output wire gpio_5_bidir_cs,
    output wire gpio_5_bidir_sl,
    output wire gpio_5_bidir_ie,
    output wire gpio_5_bidir_pu,
    output wire gpio_5_bidir_pd,

    input  wire gpio_6_bidir_in,    // gpio_6 PAD
    output wire gpio_6_bidir_out,
    output wire gpio_6_bidir_oe,
    output wire gpio_6_bidir_cs,
    output wire gpio_6_bidir_sl,
    output wire gpio_6_bidir_ie,
    output wire gpio_6_bidir_pu,
    output wire gpio_6_bidir_pd,

    input  wire gpio_7_bidir_in,    // gpio_7 PAD
    output wire gpio_7_bidir_out,
    output wire gpio_7_bidir_oe,
    output wire gpio_7_bidir_cs,
    output wire gpio_7_bidir_sl,
    output wire gpio_7_bidir_ie,
    output wire gpio_7_bidir_pu,
    output wire gpio_7_bidir_pd,

    input  wire gpio_8_bidir_in,    // gpio_8 PAD
    output wire gpio_8_bidir_out,
    output wire gpio_8_bidir_oe,
    output wire gpio_8_bidir_cs,
    output wire gpio_8_bidir_sl,
    output wire gpio_8_bidir_ie,
    output wire gpio_8_bidir_pu,
    output wire gpio_8_bidir_pd,

    input  wire gpio_9_bidir_in,    // gpio_9 PAD
    output wire gpio_9_bidir_out,
    output wire gpio_9_bidir_oe,
    output wire gpio_9_bidir_cs,
    output wire gpio_9_bidir_sl,
    output wire gpio_9_bidir_ie,
    output wire gpio_9_bidir_pu,
    output wire gpio_9_bidir_pd,

    input  wire gpio_10_bidir_in,   // gpio_10 PAD
    output wire gpio_10_bidir_out,
    output wire gpio_10_bidir_oe,
    output wire gpio_10_bidir_cs,
    output wire gpio_10_bidir_sl,
    output wire gpio_10_bidir_ie,
    output wire gpio_10_bidir_pu,
    output wire gpio_10_bidir_pd,

    input  wire gpio_11_bidir_in,   // gpio_11 PAD
    output wire gpio_11_bidir_out,
    output wire gpio_11_bidir_oe,
    output wire gpio_11_bidir_cs,
    output wire gpio_11_bidir_sl,
    output wire gpio_11_bidir_ie,
    output wire gpio_11_bidir_pu,
    output wire gpio_11_bidir_pd,

    input  wire gpio_12_bidir_in,   // gpio_12 PAD
    output wire gpio_12_bidir_out,
    output wire gpio_12_bidir_oe,
    output wire gpio_12_bidir_cs,
    output wire gpio_12_bidir_sl,
    output wire gpio_12_bidir_ie,
    output wire gpio_12_bidir_pu,
    output wire gpio_12_bidir_pd,

    input  wire gpio_13_bidir_in,   // gpio_13 PAD
    output wire gpio_13_bidir_out,
    output wire gpio_13_bidir_oe,
    output wire gpio_13_bidir_cs,
    output wire gpio_13_bidir_sl,
    output wire gpio_13_bidir_ie,
    output wire gpio_13_bidir_pu,
    output wire gpio_13_bidir_pd,

    input  wire gpio_14_bidir_in,   // gpio_14 PAD
    output wire gpio_14_bidir_out,
    output wire gpio_14_bidir_oe,
    output wire gpio_14_bidir_cs,
    output wire gpio_14_bidir_sl,
    output wire gpio_14_bidir_ie,
    output wire gpio_14_bidir_pu,
    output wire gpio_14_bidir_pd,

    input  wire gpio_15_bidir_in,   // gpio_15 PAD
    output wire gpio_15_bidir_out,
    output wire gpio_15_bidir_oe,
    output wire gpio_15_bidir_cs,
    output wire gpio_15_bidir_sl,
    output wire gpio_15_bidir_ie,
    output wire gpio_15_bidir_pu,
    output wire gpio_15_bidir_pd

);

    // --- Grouper SoC --------------------------------------------------------
    //
    // Instance name is load-bearing: librelane/classic/config.yaml places the
    // SRAM macros by their full flattened path from this module, which starts
    // u_grouper_soc_top...
    //
    // The concatenations are the GPIO pad map: bit N of each vector is the pad
    // named gpio_N_bidir_*.

    grouper_soc_top #(
        .NUM_GPIO       (16)
    ) u_grouper_soc_top (
        .clk            (clk),
        .async_rst_n    (rst_n),

        .uart_tx        (uart_tx),
        .uart_rx        (uart_rx),

        .gpio_in        ({gpio_15_bidir_in, gpio_14_bidir_in, gpio_13_bidir_in, gpio_12_bidir_in, gpio_11_bidir_in,
                             gpio_10_bidir_in, gpio_9_bidir_in, gpio_8_bidir_in, gpio_7_bidir_in, gpio_6_bidir_in,
                             gpio_5_bidir_in, gpio_4_bidir_in, gpio_3_bidir_in, gpio_2_bidir_in, gpio_1_bidir_in,
                             gpio_0_bidir_in}),

        .gpio_out       ({gpio_15_bidir_out, gpio_14_bidir_out, gpio_13_bidir_out, gpio_12_bidir_out, gpio_11_bidir_out,
                             gpio_10_bidir_out, gpio_9_bidir_out, gpio_8_bidir_out, gpio_7_bidir_out, gpio_6_bidir_out,
                             gpio_5_bidir_out, gpio_4_bidir_out, gpio_3_bidir_out, gpio_2_bidir_out, gpio_1_bidir_out,
                             gpio_0_bidir_out}),

        .gpio_oe        ({gpio_15_bidir_oe, gpio_14_bidir_oe, gpio_13_bidir_oe, gpio_12_bidir_oe, gpio_11_bidir_oe,
                             gpio_10_bidir_oe, gpio_9_bidir_oe, gpio_8_bidir_oe, gpio_7_bidir_oe, gpio_6_bidir_oe,
                             gpio_5_bidir_oe, gpio_4_bidir_oe, gpio_3_bidir_oe, gpio_2_bidir_oe, gpio_1_bidir_oe,
                             gpio_0_bidir_oe}),

        .gpio_cs        ({gpio_15_bidir_cs, gpio_14_bidir_cs, gpio_13_bidir_cs, gpio_12_bidir_cs, gpio_11_bidir_cs,
                             gpio_10_bidir_cs, gpio_9_bidir_cs, gpio_8_bidir_cs, gpio_7_bidir_cs, gpio_6_bidir_cs,
                             gpio_5_bidir_cs, gpio_4_bidir_cs, gpio_3_bidir_cs, gpio_2_bidir_cs, gpio_1_bidir_cs,
                             gpio_0_bidir_cs}),

        .gpio_sl        ({gpio_15_bidir_sl, gpio_14_bidir_sl, gpio_13_bidir_sl, gpio_12_bidir_sl, gpio_11_bidir_sl,
                             gpio_10_bidir_sl, gpio_9_bidir_sl, gpio_8_bidir_sl, gpio_7_bidir_sl, gpio_6_bidir_sl,
                             gpio_5_bidir_sl, gpio_4_bidir_sl, gpio_3_bidir_sl, gpio_2_bidir_sl, gpio_1_bidir_sl,
                             gpio_0_bidir_sl}),

        .gpio_ie        ({gpio_15_bidir_ie, gpio_14_bidir_ie, gpio_13_bidir_ie, gpio_12_bidir_ie, gpio_11_bidir_ie,
                             gpio_10_bidir_ie, gpio_9_bidir_ie, gpio_8_bidir_ie, gpio_7_bidir_ie, gpio_6_bidir_ie,
                             gpio_5_bidir_ie, gpio_4_bidir_ie, gpio_3_bidir_ie, gpio_2_bidir_ie, gpio_1_bidir_ie,
                             gpio_0_bidir_ie}),

        .gpio_pu        ({gpio_15_bidir_pu, gpio_14_bidir_pu, gpio_13_bidir_pu, gpio_12_bidir_pu, gpio_11_bidir_pu,
                             gpio_10_bidir_pu, gpio_9_bidir_pu, gpio_8_bidir_pu, gpio_7_bidir_pu, gpio_6_bidir_pu,
                             gpio_5_bidir_pu, gpio_4_bidir_pu, gpio_3_bidir_pu, gpio_2_bidir_pu, gpio_1_bidir_pu,
                             gpio_0_bidir_pu}),

        .gpio_pd        ({gpio_15_bidir_pd, gpio_14_bidir_pd, gpio_13_bidir_pd, gpio_12_bidir_pd, gpio_11_bidir_pd,
                             gpio_10_bidir_pd, gpio_9_bidir_pd, gpio_8_bidir_pd, gpio_7_bidir_pd, gpio_6_bidir_pd,
                             gpio_5_bidir_pd, gpio_4_bidir_pd, gpio_3_bidir_pd, gpio_2_bidir_pd, gpio_1_bidir_pd,
                             gpio_0_bidir_pd})
    );

endmodule

`default_nettype wire
