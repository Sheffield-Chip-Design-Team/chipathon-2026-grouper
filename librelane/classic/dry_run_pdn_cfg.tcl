# Copyright 2025 LibreLane Contributors
#
# Adapted from OpenLane
#
# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

# ---------------------------------------------------------------------------
# Layer stack for the dry run (chip_core, no SRAM macros)
#
# Derived from pdn_cfg.tcl. The only structural difference is the missing
# sram_grid at the end of that file: the dry run does not instantiate the
# gf180mcu_ocd_ip_sram__sram1024x8m8wm1 macros (hw/rtl/memory/ahb_ram.sv is
# built with `DRY_RUN, which replaces the memory with counters), so a
# -macro grid matching on that cell master has nothing to match and is
# dropped rather than left to fail silently.
#
# Structure:
#
#   Metal5   general mesh horizontal straps (PDN_HORIZONTAL_LAYER) -- normally
#            reserved for a hierarchical parent's core ring; carries our own
#            mesh here. See the "Metal5 ownership" note in dry_run_config.yaml.
#   Metal4   vertical straps, full die height
#   Metal3   SPARSE rung stripes only (pdn_rung_pitch below, much coarser than
#            a full-density mesh). Existing only to give Metal2-Metal4 a
#            reliable connection, not to carry current itself -- see below.
#   Metal2   vertical straps, coincident with Metal4
#   Metal1   followpin rails on the std cell VDD/VSS pins
#
# Why the Metal3 rungs exist at all (learned the hard way, and still true
# without the macros): an earlier version of pdn_cfg.tcl dropped the Metal3
# mesh entirely and connected Metal2 straight to Metal4 with a single
# add_pdn_connect. Metal2 and Metal4 are BOTH vertical (parallel, not
# crossing), so pdngen has no well-defined intersection point to drop a real
# via at -- it tried to via-stack through Metal3 anyway and produced
# degenerate, functionally disconnected slivers (0.01um wide) instead of real
# vias, surfacing as 1524 real PSM-0069 connectivity violations at 1310x1150
# -- see TRIAL_NOTES.md. Metal3 (horizontal) crossing Metal2/Metal4
# (vertical) is a real perpendicular intersection, which pdngen handles
# reliably. Keeping a few sparse Metal3 rungs restores that reliability
# without reinstating the full-density mesh that caused the original routing
# congestion.
#
# Every add_pdn_connect below joins layers that pdngen can via-stack at
# overlapping stripe locations (adjacent layers get a single via; Metal3
# rungs crossing Metal2/Metal4 are true perpendicular intersections).
#
# NOTE: the Metal4 requirement below is inherited from the SRAM-bearing
# config, where Metal4 was the only unobstructed layer. Without macros that
# constraint is no longer physical -- it is kept so the two PDN scripts stay
# comparable, and so a layer change has to be a deliberate edit here.
# ---------------------------------------------------------------------------
if { $::env(PDN_VERTICAL_LAYER) != "Metal4" } {
    throw APPLICATION "dry run expects Metal4 vertical straps to match pdn_cfg.tcl, got $::env(PDN_VERTICAL_LAYER)."
}
if { $::env(PDN_RAIL_LAYER) != "Metal1" } {
    throw APPLICATION "gf180mcu_fd_sc_mcu7t5v0 exposes VDD/VSS on Metal1, got $::env(PDN_RAIL_LAYER)."
}

# Intermediate vertical layer bridging the Metal1 rails up to the Metal4 straps.
set pdn_intermediate_layer "Metal2"

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd

        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }

    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd

        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary



if { $::env(PDN_MULTILAYER) == 1 } {

    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid \
        -name stdcell_grid \
        -starts_with POWER \
        -voltage_domain CORE \
        {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    # Top vertical straps, full die height. These are what a hierarchical
    # parent vias down onto.
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    # Horizontal mesh.
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) \
        -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) \
        -spacing $::env(PDN_HSPACING) \
        -starts_with POWER \
        {*}$arg_list

    # Intermediate vertical stripes, coincident in x with the Metal4 straps
    # (same pitch, offset and spacing). Metal2 is vertical-preferred in
    # gf180mcu, so these are in-direction.
    #
    # Cost: PDN_VWIDTH every PDN_VPITCH of Metal2, ~7% of the layer.
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $pdn_intermediate_layer \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    # Sparse Metal3 rungs. Real perpendicular crossings with the Metal2 and
    # Metal4 vertical stripes -- see the "why the Metal3 rungs exist" note
    # above. pdn_rung_pitch is hardcoded here rather than a config variable:
    # LibreLane validates config.yaml keys against a fixed schema and
    # rejects unrecognized ones outright, and this is an internal
    # implementation detail, not something a run needs to tune per-die-size.
    # Intentionally much coarser than PDN_HPITCH/PDN_VPITCH: this layer
    # exists to make Metal2-Metal4 vias reliable, not to carry general
    # current, so it should stay a small fraction of Metal3's routing
    # resource - and Metal3 is the layer that ran out first in the original
    # congestion investigation.
    #
    # Width/pitch/offset are Metal3's own, NOT PDN_HWIDTH/PDN_HOFFSET: those
    # now size the Metal5 mesh and are multiples of Metal5's 0.90um track
    # pitch, which is not a whole number of Metal3's 0.56um tracks. Reusing
    # them here would put every rung off the Metal3 routing grid and poison
    # the tracks alongside it - the same defect that stalled detailed routing
    # on Metal2 (see the strap note in dry_run_config.yaml).
    #
    # At 448um pitch the mesh still gives each Metal2 stripe ~5 rung
    # crossings over the 1100um die, far more than connectivity needs.
    set pdn_rung_layer   "Metal3"
    set pdn_rung_width   5.04    ;# 9 x 0.56 Metal3 track pitch
    set pdn_rung_pitch   448     ;# 800 x 0.56
    set pdn_rung_offset  13.44   ;# 24 x 0.56
    set pdn_rung_spacing [expr {($pdn_rung_pitch - 2 * $pdn_rung_width) / 2}]  ;# 391 x 0.56
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $pdn_rung_layer \
        -width $pdn_rung_width \
        -pitch $pdn_rung_pitch \
        -offset $pdn_rung_offset \
        -spacing $pdn_rung_spacing \
        -starts_with POWER \
        {*}$arg_list

    # Metal4-Metal5: adjacent, single Via4. The top of the general mesh.
    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"

    # Metal2-Metal3(rung) and Metal3(rung)-Metal4: the real rail-to-grid
    # bridge, via true perpendicular crossings rather than the fragile
    # same-direction Metal2-Metal4 direct connect this file used to have.
    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$pdn_intermediate_layer $pdn_rung_layer"

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$pdn_rung_layer $::env(PDN_VERTICAL_LAYER)"
} else {

    throw APPLICATION "the dry run requires PDN_MULTILAYER: the Metal1 rails need a Metal2/Metal3/Metal4 bridge up to the mesh."
}

# Standard cell rails.
#
# gf180mcu_fd_sc_mcu7t5v0 exposes VDD / VSS on Metal1 (no li1-style layer),
# so PDN_RAIL_LAYER must be Metal1. The rails connect up to the Metal2
# intermediate stripes -- one Via1, not a three-cut stack.
if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) \
        -followpins

    add_pdn_connect \
        -grid stdcell_grid \
        -layers "$::env(PDN_RAIL_LAYER) $pdn_intermediate_layer"
}


# Core ring.
#
# NOTE: the dry run sets PDN_CORE_RING: false. This macro integrates
# hierarchically rather than standing alone with its own ring. Historically
# that also meant leaving Metal5 untouched for the parent's straps; as of
# the general mesh moving to Metal5 (PDN_HORIZONTAL_LAYER), that reservation
# is no longer automatic -- Metal5 ownership between this macro and its
# parent needs to be coordinated explicitly, not assumed from this setting.
# A core ring would only be needed for the "ring" integration method, or at
# chip top where it bonds to the padframe. Block retained for upstream diffs.
if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS -connect_to_pads
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring \
            -grid stdcell_grid \
            -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offsets "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect \
                -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }

    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}

