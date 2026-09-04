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

# ---------------------------------------------------------------------------
# False paths: intentionally async control signals
# ---------------------------------------------------------------------------
#
# dbg_own (hw/rtl/debug/dbg_ctrl.sv, driven by the status_lock_active reg,
# GRPR-DBG-043) is a debug bus-ownership mode-select, not a per-cycle data
# path - it only moves on a LOCK/UNLOCK/RESUME debug-port event, and
# dbg_ctrl's own FSM already holds LOCK_PENDING for a cycle before dbg_own
# moves (GRPR-DBG-009, dbg_ctrl.sv:343-346) specifically so any in-flight CPU
# access gets one more cycle to complete under mem_ready before ownership
# changes. Job 5342 (first run with the SRAM macro's ss_125C_3v00 lib
# enabled) found 333 of 394 max_ss setup violations fanning out from this one
# net through cpu_ss into spi_m/spi_s/uart_rx/the RAM macro wrappers - worst
# slack -26.86 ns. That's timing pressure on a mode-select signal that was
# never meant to close same-cycle.
#
# `-hierarchical` doesn't help here: Yosys.Synthesis flattens the design (see
# grouper_soc_chip_core.nl.v), so by the time OpenROAD reads this SDC there is
# no hierarchy left for -hierarchical to descend - just one flat net whose
# name happens to contain literal dots from the flattening scheme:
# `u_grouper_soc_top.u_grouper_soc_dig_ss.u_cpu_ss.dbg_own`. get_nets with a
# bare, non-wildcarded `dbg_own` pattern does an exact match against that
# whole flat name and finds nothing - confirmed as
# "Warning: grouper_chip_core.sdc line 103, net 'dbg_own' not found." in
# every corner's 10-openroad-staprepnr/*/sta.log (job 5347, the run this
# exception was meant to fix, and still present at 53-openroad-stapostpnr -
# the exception never took, which is why job 5347's max_ss violations went
# up (409) instead of down from job 5342's 394). A leading glob picks up the
# flat name by suffix instead of requiring an exact match.
set_false_path -through [get_nets {*dbg_own}]

# gpio_*_bidir_in, when gpio_sync_en_n[i] is set, bypasses the 2-FF
# synchroniser entirely (grouper_soc_top.sv:68, gpio_in_dig[i] =
# gpio_sync_en_n[i] ? gpio_in[i] : gpio_in_sync[i]) and reaches downstream
# logic combinationally - "a deliberate CDC opt-out... no metastability
# guarantee is made for a bypassed pad" (grouper_soc_top.sv:54-56).
# gpio_sync_en_n is a software-writable register (ahb_gpio_ctrl.sv), not
# tied off, so this is a real path in the netlist: 61 of job 5342's 394
# max_ss violations were gpio_1/gpio_15 taking this route straight into
# cpu_ss. False-pathing the whole port also excepts its port-to-first-
# sync-flop leg, but every GPIO pad input is documented above as an async
# board-level signal ahead of the synchroniser in the first place, so that
# leg was never a real same-cycle check either.
#
# Only gpio_1/gpio_15 violated in job 5342 - the bypass mux is identical on
# all NUM_GPIO pins, so this is a per-run placement artifact, not something
# special about these two. Revisit whether all *_bidir_in ports should carry
# this exception instead of just the two that happened to fail this run.
set_false_path -from [get_ports {gpio_1_bidir_in gpio_15_bidir_in}]
