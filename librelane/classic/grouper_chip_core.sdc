# Constraints for the LibreLane dry run (dry_run_config.yaml).
#
# The top level is `chip_core` (hw/pd/grouper_soc_chip_core.sv), which is the
# core *inside* the padring - its ports are the SoC-side signals (clk, rst_n,
# input_in/pu/pd, bidir_in/out/oe/cs/sl/ie/pu/pd), not the *_PAD ports of
# chip_top. grouper_chip_core.sdc constrains the chip_top names and does not
# match this design; this file is the chip_core equivalent.

current_design $::env(DESIGN_NAME)
set_units -time ns

# clk is a real port on chip_core - no I/O pad in this flow, so no CLOCK_NET
# indirection (the config sets none, and dereferencing it would throw).
set clock_port [lindex $::env(CLOCK_PORT) 0]

puts "\[INFO] Using clock $clock_port…"
create_clock [get_ports $clock_port] -name $clock_port -period $::env(CLOCK_PERIOD)

set input_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set output_delay_value [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
puts "\[INFO] Setting output delay to: $output_delay_value"
puts "\[INFO] Setting input delay to: $input_delay_value"

set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if { [info exists ::env(MAX_TRANSITION_CONSTRAINT)] } {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if { [info exists ::env(MAX_CAPACITANCE_CONSTRAINT)] } {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set clocks [get_clocks $clock_port]

# Inputs: async reset, uart_rx, and the pad-side input values coming back from
# the padring. gpio_*_bidir_in is an input to chip_core even though the pad is
# bidirectional.
#
# chip_core's pad-facing ports are flat scalars named
# <function>_<pad kind>_<signal> - `gpio_0_bidir_in` - so these are name globs,
# not bus selects, and the leading `*` is what catches every function prefix.
# `bidir_in[*]` would match nothing and STA would report "[STA-0366] port
# 'bidir_in[*]' not found", leaving the ports with no input delay at all.
set core_input_ports [get_ports {
    rst_n
    uart_rx
    *_bidir_in
}]

set_input_delay -min 0                   -clock $clocks $core_input_ports
set_input_delay -max $input_delay_value  -clock $clocks $core_input_ports

# Outputs: everything chip_core drives towards the padring - uart_tx, plus each
# GPIO pad's value and its six control lines.
set core_output_ports [get_ports {
    uart_tx
    *_bidir_out
    *_bidir_oe
    *_bidir_cs
    *_bidir_sl
    *_bidir_ie
    *_bidir_pu
    *_bidir_pd
}]

set_output_delay $output_delay_value -clock $clocks $core_output_ports

# Output load
set cap_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0]
puts "\[INFO] Setting load to: $cap_load"
set_load $cap_load [all_outputs]

puts "\[INFO] Setting clock uncertainty to: $::env(CLOCK_UNCERTAINTY_CONSTRAINT)"
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks

puts "\[INFO] Setting clock transition to: $::env(CLOCK_TRANSITION_CONSTRAINT)"
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks

puts "\[INFO] Setting timing derate to: $::env(TIME_DERATING_CONSTRAINT)%"
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]

if { [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) } {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}
