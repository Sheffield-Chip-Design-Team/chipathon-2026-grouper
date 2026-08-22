// SPDX-FileCopyrightText: © 2025 Project Template Contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

`include "slot_defines.svh"

module chip_top #(
    // Power/ground pads for core and I/O
    parameter NUM_DVDD_PADS = `NUM_DVDD_PADS,
    parameter NUM_DVSS_PADS = `NUM_DVSS_PADS,

    // Signal pads
    parameter NUM_INPUT_PADS = `NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS = `NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS = `NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    inout  wire clk_PAD,
    inout  wire rst_n_PAD,
    
    inout  wire [NUM_INPUT_PADS-1:0] input_PAD,
    inout  wire [NUM_BIDIR_PADS-1:0] bidir_PAD,
    
    inout  wire [NUM_ANALOG_PADS-1:0] analog_PAD
);

    // Pad assignment. CORE_GPIO_PADS is fixed in grouper_soc_chip_core.sv (a
    // flat port list cannot be parameterised) and must be kept in step with the
    // NUM_GPIO the dig top uses; the two UART pads are placed here.
    localparam int unsigned CORE_GPIO_PADS = 16;
    localparam int unsigned UART_RX_PAD    = 0;                // input pad
    localparam int unsigned UART_TX_PAD    = CORE_GPIO_PADS;   // bidir pad

    wire clk_PAD2CORE;
    wire rst_n_PAD2CORE;
    
    wire [NUM_INPUT_PADS-1:0] input_PAD2CORE;
    wire [NUM_INPUT_PADS-1:0] input_CORE2PAD_PU;
    wire [NUM_INPUT_PADS-1:0] input_CORE2PAD_PD;

    wire [NUM_BIDIR_PADS-1:0] bidir_PAD2CORE;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_OE;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_CS;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_SL;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_IE;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_PU;
    wire [NUM_BIDIR_PADS-1:0] bidir_CORE2PAD_PD;

    // Power/ground pad instances
    generate
    for (genvar i=0; i<NUM_DVDD_PADS; i++) begin : dvdd_pads
        (* keep *)
        gf180mcu_ws_io__dvdd pad (
            `ifdef USE_POWER_PINS
            .DVDD   (VDD),
            .DVSS   (VSS),
            .VSS    (VSS)
            `endif
        );
    end
    
    for (genvar i=0; i<NUM_DVSS_PADS; i++) begin : dvss_pads
        (* keep *)
        gf180mcu_ws_io__dvss pad (
            `ifdef USE_POWER_PINS
            .DVDD   (VDD),
            .DVSS   (VSS),
            .VDD    (VDD)
            `endif
        );
    end
    endgenerate

    // Signal IO pad instances

    // Schmitt trigger
    gf180mcu_fd_io__in_s clk_pad (
        `ifdef USE_POWER_PINS
        .DVDD   (VDD),
        .DVSS   (VSS),
        .VDD    (VDD),
        .VSS    (VSS),
        `endif
    
        .Y      (clk_PAD2CORE),
        .PAD    (clk_PAD),
        
        .PU     (1'b0),
        .PD     (1'b0)
    );
    
    // Normal input
    gf180mcu_fd_io__in_c rst_n_pad (
        `ifdef USE_POWER_PINS
        .DVDD   (VDD),
        .DVSS   (VSS),
        .VDD    (VDD),
        .VSS    (VSS),
        `endif
    
        .Y      (rst_n_PAD2CORE),
        .PAD    (rst_n_PAD),
        
        .PU     (1'b0),
        .PD     (1'b0)
    );

    generate
    for (genvar i=0; i<NUM_INPUT_PADS; i++) begin : inputs
        (* keep *)
        gf180mcu_fd_io__in_c pad (
            `ifdef USE_POWER_PINS
            .DVDD   (VDD),
            .DVSS   (VSS),
            .VDD    (VDD),
            .VSS    (VSS),
            `endif
        
            .Y      (input_PAD2CORE[i]),
            .PAD    (input_PAD[i]),
            
            .PU     (input_CORE2PAD_PU[i]),
            .PD     (input_CORE2PAD_PD[i])
        );
    end
    endgenerate

    generate
    for (genvar i=0; i<NUM_BIDIR_PADS; i++) begin : bidir
        (* keep *)
        gf180mcu_fd_io__bi_24t pad (
            `ifdef USE_POWER_PINS
            .DVDD   (VDD),
            .DVSS   (VSS),
            .VDD    (VDD),
            .VSS    (VSS),
            `endif
        
            .A      (bidir_CORE2PAD[i]),
            .OE     (bidir_CORE2PAD_OE[i]),
            .Y      (bidir_PAD2CORE[i]),
            .PAD    (bidir_PAD[i]),
            
            .CS     (bidir_CORE2PAD_CS[i]),
            .SL     (bidir_CORE2PAD_SL[i]),
            .IE     (bidir_CORE2PAD_IE[i]),

            .PU     (bidir_CORE2PAD_PU[i]),
            .PD     (bidir_CORE2PAD_PD[i])
        );
    end
    endgenerate

    generate
    for (genvar i=0; i<NUM_ANALOG_PADS; i++) begin : analog
        (* keep *)
        gf180mcu_fd_io__asig_5p0 pad (
            `ifdef USE_POWER_PINS
            .DVDD   (VDD),
            .DVSS   (VSS),
            .VDD    (VDD),
            .VSS    (VSS),
            `endif
            .ASIG5V (analog_PAD[i])
        );
    end
    endgenerate

    // Core design
    //
    // grouper_soc_chip_core exposes a pad-control interface for the GPIO pads
    // only - they are the only pads the SoC configures at run time. uart_rx and
    // uart_tx come out as plain signals, so putting them on pads is this
    // module's job, as is every pad the core does not reach:
    //
    //   bidir_PAD[CORE_GPIO_PADS-1:0]     gpio[15:0], driven by the core
    //   input_PAD[UART_RX_PAD]            uart_rx, pulls off
    //   bidir_PAD[UART_TX_PAD]            uart_tx, permanent output, input buffer off
    //   input_PAD[NUM_INPUT_PADS-1:1]     spare, tied off
    //   bidir_PAD[NUM_BIDIR_PADS-1:17]    spare, tied off
    //
    // The core's budget is the pads it configures and nothing more, so this
    // holds for every slot in slot_defines.svh - only the number of pads tied
    // off below changes.

    grouper_soc_chip_core i_chip_core (
        .clk        (clk_PAD2CORE),
        .rst_n      (rst_n_PAD2CORE),

        .uart_rx    (input_PAD2CORE[UART_RX_PAD]),
        .uart_tx    (bidir_CORE2PAD[UART_TX_PAD]),

        .gpio_0_bidir_in   (bidir_PAD2CORE[0]),         // gpio0
        .gpio_0_bidir_out  (bidir_CORE2PAD[0]),
        .gpio_0_bidir_oe   (bidir_CORE2PAD_OE[0]),
        .gpio_0_bidir_cs   (bidir_CORE2PAD_CS[0]),
        .gpio_0_bidir_sl   (bidir_CORE2PAD_SL[0]),
        .gpio_0_bidir_ie   (bidir_CORE2PAD_IE[0]),
        .gpio_0_bidir_pu   (bidir_CORE2PAD_PU[0]),
        .gpio_0_bidir_pd   (bidir_CORE2PAD_PD[0]),

        .gpio_1_bidir_in   (bidir_PAD2CORE[1]),         // gpio1
        .gpio_1_bidir_out  (bidir_CORE2PAD[1]),
        .gpio_1_bidir_oe   (bidir_CORE2PAD_OE[1]),
        .gpio_1_bidir_cs   (bidir_CORE2PAD_CS[1]),
        .gpio_1_bidir_sl   (bidir_CORE2PAD_SL[1]),
        .gpio_1_bidir_ie   (bidir_CORE2PAD_IE[1]),
        .gpio_1_bidir_pu   (bidir_CORE2PAD_PU[1]),
        .gpio_1_bidir_pd   (bidir_CORE2PAD_PD[1]),

        .gpio_2_bidir_in   (bidir_PAD2CORE[2]),         // gpio2
        .gpio_2_bidir_out  (bidir_CORE2PAD[2]),
        .gpio_2_bidir_oe   (bidir_CORE2PAD_OE[2]),
        .gpio_2_bidir_cs   (bidir_CORE2PAD_CS[2]),
        .gpio_2_bidir_sl   (bidir_CORE2PAD_SL[2]),
        .gpio_2_bidir_ie   (bidir_CORE2PAD_IE[2]),
        .gpio_2_bidir_pu   (bidir_CORE2PAD_PU[2]),
        .gpio_2_bidir_pd   (bidir_CORE2PAD_PD[2]),

        .gpio_3_bidir_in   (bidir_PAD2CORE[3]),         // gpio3
        .gpio_3_bidir_out  (bidir_CORE2PAD[3]),
        .gpio_3_bidir_oe   (bidir_CORE2PAD_OE[3]),
        .gpio_3_bidir_cs   (bidir_CORE2PAD_CS[3]),
        .gpio_3_bidir_sl   (bidir_CORE2PAD_SL[3]),
        .gpio_3_bidir_ie   (bidir_CORE2PAD_IE[3]),
        .gpio_3_bidir_pu   (bidir_CORE2PAD_PU[3]),
        .gpio_3_bidir_pd   (bidir_CORE2PAD_PD[3]),

        .gpio_4_bidir_in   (bidir_PAD2CORE[4]),         // gpio4
        .gpio_4_bidir_out  (bidir_CORE2PAD[4]),
        .gpio_4_bidir_oe   (bidir_CORE2PAD_OE[4]),
        .gpio_4_bidir_cs   (bidir_CORE2PAD_CS[4]),
        .gpio_4_bidir_sl   (bidir_CORE2PAD_SL[4]),
        .gpio_4_bidir_ie   (bidir_CORE2PAD_IE[4]),
        .gpio_4_bidir_pu   (bidir_CORE2PAD_PU[4]),
        .gpio_4_bidir_pd   (bidir_CORE2PAD_PD[4]),

        .gpio_5_bidir_in   (bidir_PAD2CORE[5]),         // gpio5
        .gpio_5_bidir_out  (bidir_CORE2PAD[5]),
        .gpio_5_bidir_oe   (bidir_CORE2PAD_OE[5]),
        .gpio_5_bidir_cs   (bidir_CORE2PAD_CS[5]),
        .gpio_5_bidir_sl   (bidir_CORE2PAD_SL[5]),
        .gpio_5_bidir_ie   (bidir_CORE2PAD_IE[5]),
        .gpio_5_bidir_pu   (bidir_CORE2PAD_PU[5]),
        .gpio_5_bidir_pd   (bidir_CORE2PAD_PD[5]),

        .gpio_6_bidir_in   (bidir_PAD2CORE[6]),         // gpio6
        .gpio_6_bidir_out  (bidir_CORE2PAD[6]),
        .gpio_6_bidir_oe   (bidir_CORE2PAD_OE[6]),
        .gpio_6_bidir_cs   (bidir_CORE2PAD_CS[6]),
        .gpio_6_bidir_sl   (bidir_CORE2PAD_SL[6]),
        .gpio_6_bidir_ie   (bidir_CORE2PAD_IE[6]),
        .gpio_6_bidir_pu   (bidir_CORE2PAD_PU[6]),
        .gpio_6_bidir_pd   (bidir_CORE2PAD_PD[6]),

        .gpio_7_bidir_in   (bidir_PAD2CORE[7]),         // gpio7
        .gpio_7_bidir_out  (bidir_CORE2PAD[7]),
        .gpio_7_bidir_oe   (bidir_CORE2PAD_OE[7]),
        .gpio_7_bidir_cs   (bidir_CORE2PAD_CS[7]),
        .gpio_7_bidir_sl   (bidir_CORE2PAD_SL[7]),
        .gpio_7_bidir_ie   (bidir_CORE2PAD_IE[7]),
        .gpio_7_bidir_pu   (bidir_CORE2PAD_PU[7]),
        .gpio_7_bidir_pd   (bidir_CORE2PAD_PD[7]),

        .gpio_8_bidir_in   (bidir_PAD2CORE[8]),         // gpio8
        .gpio_8_bidir_out  (bidir_CORE2PAD[8]),
        .gpio_8_bidir_oe   (bidir_CORE2PAD_OE[8]),
        .gpio_8_bidir_cs   (bidir_CORE2PAD_CS[8]),
        .gpio_8_bidir_sl   (bidir_CORE2PAD_SL[8]),
        .gpio_8_bidir_ie   (bidir_CORE2PAD_IE[8]),
        .gpio_8_bidir_pu   (bidir_CORE2PAD_PU[8]),
        .gpio_8_bidir_pd   (bidir_CORE2PAD_PD[8]),

        .gpio_9_bidir_in   (bidir_PAD2CORE[9]),         // gpio9
        .gpio_9_bidir_out  (bidir_CORE2PAD[9]),
        .gpio_9_bidir_oe   (bidir_CORE2PAD_OE[9]),
        .gpio_9_bidir_cs   (bidir_CORE2PAD_CS[9]),
        .gpio_9_bidir_sl   (bidir_CORE2PAD_SL[9]),
        .gpio_9_bidir_ie   (bidir_CORE2PAD_IE[9]),
        .gpio_9_bidir_pu   (bidir_CORE2PAD_PU[9]),
        .gpio_9_bidir_pd   (bidir_CORE2PAD_PD[9]),

        .gpio_10_bidir_in  (bidir_PAD2CORE[10]),        // gpio10
        .gpio_10_bidir_out (bidir_CORE2PAD[10]),
        .gpio_10_bidir_oe  (bidir_CORE2PAD_OE[10]),
        .gpio_10_bidir_cs  (bidir_CORE2PAD_CS[10]),
        .gpio_10_bidir_sl  (bidir_CORE2PAD_SL[10]),
        .gpio_10_bidir_ie  (bidir_CORE2PAD_IE[10]),
        .gpio_10_bidir_pu  (bidir_CORE2PAD_PU[10]),
        .gpio_10_bidir_pd  (bidir_CORE2PAD_PD[10]),

        .gpio_11_bidir_in  (bidir_PAD2CORE[11]),        // gpio11
        .gpio_11_bidir_out (bidir_CORE2PAD[11]),
        .gpio_11_bidir_oe  (bidir_CORE2PAD_OE[11]),
        .gpio_11_bidir_cs  (bidir_CORE2PAD_CS[11]),
        .gpio_11_bidir_sl  (bidir_CORE2PAD_SL[11]),
        .gpio_11_bidir_ie  (bidir_CORE2PAD_IE[11]),
        .gpio_11_bidir_pu  (bidir_CORE2PAD_PU[11]),
        .gpio_11_bidir_pd  (bidir_CORE2PAD_PD[11]),

        .gpio_12_bidir_in  (bidir_PAD2CORE[12]),        // gpio12
        .gpio_12_bidir_out (bidir_CORE2PAD[12]),
        .gpio_12_bidir_oe  (bidir_CORE2PAD_OE[12]),
        .gpio_12_bidir_cs  (bidir_CORE2PAD_CS[12]),
        .gpio_12_bidir_sl  (bidir_CORE2PAD_SL[12]),
        .gpio_12_bidir_ie  (bidir_CORE2PAD_IE[12]),
        .gpio_12_bidir_pu  (bidir_CORE2PAD_PU[12]),
        .gpio_12_bidir_pd  (bidir_CORE2PAD_PD[12]),

        .gpio_13_bidir_in  (bidir_PAD2CORE[13]),        // gpio13
        .gpio_13_bidir_out (bidir_CORE2PAD[13]),
        .gpio_13_bidir_oe  (bidir_CORE2PAD_OE[13]),
        .gpio_13_bidir_cs  (bidir_CORE2PAD_CS[13]),
        .gpio_13_bidir_sl  (bidir_CORE2PAD_SL[13]),
        .gpio_13_bidir_ie  (bidir_CORE2PAD_IE[13]),
        .gpio_13_bidir_pu  (bidir_CORE2PAD_PU[13]),
        .gpio_13_bidir_pd  (bidir_CORE2PAD_PD[13]),

        .gpio_14_bidir_in  (bidir_PAD2CORE[14]),        // gpio14
        .gpio_14_bidir_out (bidir_CORE2PAD[14]),
        .gpio_14_bidir_oe  (bidir_CORE2PAD_OE[14]),
        .gpio_14_bidir_cs  (bidir_CORE2PAD_CS[14]),
        .gpio_14_bidir_sl  (bidir_CORE2PAD_SL[14]),
        .gpio_14_bidir_ie  (bidir_CORE2PAD_IE[14]),
        .gpio_14_bidir_pu  (bidir_CORE2PAD_PU[14]),
        .gpio_14_bidir_pd  (bidir_CORE2PAD_PD[14]),

        .gpio_15_bidir_in  (bidir_PAD2CORE[15]),        // gpio15
        .gpio_15_bidir_out (bidir_CORE2PAD[15]),
        .gpio_15_bidir_oe  (bidir_CORE2PAD_OE[15]),
        .gpio_15_bidir_cs  (bidir_CORE2PAD_CS[15]),
        .gpio_15_bidir_sl  (bidir_CORE2PAD_SL[15]),
        .gpio_15_bidir_ie  (bidir_CORE2PAD_IE[15]),
        .gpio_15_bidir_pu  (bidir_CORE2PAD_PU[15]),
        .gpio_15_bidir_pd  (bidir_CORE2PAD_PD[15])
    );

    // --- Pads the core does not configure ------------------------------------

    // uart_rx: input-only pad, pulls off. Every other input pad is spare, and
    // spare input pads want exactly the same thing, so this covers the lot.
    assign input_CORE2PAD_PU = '0;
    assign input_CORE2PAD_PD = '0;

    // uart_tx: permanent output, input buffer off. Its value comes straight
    // from the core's uart_tx port, connected above.
    assign bidir_CORE2PAD_OE[UART_TX_PAD] = 1'b1;
    assign bidir_CORE2PAD_CS[UART_TX_PAD] = 1'b0;
    assign bidir_CORE2PAD_SL[UART_TX_PAD] = 1'b0;
    assign bidir_CORE2PAD_IE[UART_TX_PAD] = 1'b0;
    assign bidir_CORE2PAD_PU[UART_TX_PAD] = 1'b0;
    assign bidir_CORE2PAD_PD[UART_TX_PAD] = 1'b0;

    // Spare bidir pads: driven low so they never float, input buffer off.
    generate
    if (NUM_BIDIR_PADS > UART_TX_PAD + 1) begin : gen_spare_bidir_pads
        assign bidir_CORE2PAD   [NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
        assign bidir_CORE2PAD_OE[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '1;
        assign bidir_CORE2PAD_CS[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
        assign bidir_CORE2PAD_SL[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
        assign bidir_CORE2PAD_IE[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
        assign bidir_CORE2PAD_PU[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
        assign bidir_CORE2PAD_PD[NUM_BIDIR_PADS-1:UART_TX_PAD+1] = '0;
    end
    endgenerate

    // Chip ID - do not remove, necessary for tapeout
    (* keep *)
    gf180mcu_ws_ip__id chip_id ();
    
    // wafer.space logo - can be removed
    (* keep *)
    gf180mcu_ws_ip__logo wafer_space_logo ();
endmodule

`default_nettype wire
