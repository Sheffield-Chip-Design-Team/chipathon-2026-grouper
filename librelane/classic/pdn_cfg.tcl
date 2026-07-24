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
# Layer stack for picorv32_hello_top
#
# gf180mcu_ocd_ip_sram__sram1024x8m8wm1 obstructs Metal1, Metal2 and Metal3
# across its entire interior (3.0 .. 298.3 x 3.0 .. 512.81) and exposes VDD /
# VSS only on a ~3um Metal3 perimeter frame. Metal4 is unobstructed, so it is
# the only layer that can carry power over the macro, and Metal3 is the only
# layer that can receive it -- that part is fixed by the SRAM's own LEF and
# does not depend on PDN_HORIZONTAL_LAYER below.
#
# Structure:
#
#   Metal5   general mesh horizontal straps (PDN_HORIZONTAL_LAYER) -- was
#            reserved for the parent's core ring; now carries our own mesh.
#            See the "Metal5 ownership" note above this file's call site.
#   Metal4   vertical straps, full die height, cross the SRAMs
#   Metal3   SPARSE rung stripes only (pdn_rung_pitch below, much coarser than
#            the old full-density mesh), plus the SRAM's own exposed pin tabs
#            (sram_grid connect, hardcoded to Metal3 regardless of
#            PDN_HORIZONTAL_LAYER -- see below). Existing only to give
#            Metal2-Metal4 a reliable connection, not to carry current
#            itself -- see the note on why below.
#   Metal2   vertical straps, coincident with Metal4, trimmed at the SRAMs
#   Metal1   followpin rails on the std cell VDD/VSS pins
#
# Why the Metal3 rungs exist at all (learned the hard way): an earlier
# version of this file dropped the Metal3 mesh entirely and connected
# Metal2 straight to Metal4 with a single add_pdn_connect. Metal2 and
# Metal4 are BOTH vertical (parallel, not crossing), so pdngen has no
# well-defined intersection point to drop a real via at -- it tried to
# via-stack through Metal3 anyway and produced degenerate, functionally
# disconnected slivers (0.01um wide) instead of real vias. This was masked
# at some die sizes (the two paths were redundant with a full Metal3 mesh)
# and surfaced as 1524 real PSM-0069 connectivity violations at others
# (1310x1150) the moment the full mesh was removed -- see TRIAL_NOTES.md.
# Metal3 (horizontal) crossing Metal2/Metal4 (vertical) is a real
# perpendicular intersection, which pdngen handles reliably. Keeping a few
# sparse Metal3 rungs restores that reliability without reinstating the
# full-density mesh that caused the original routing congestion.
#
# Every add_pdn_connect below joins layers that pdngen can via-stack at
# overlapping stripe locations (adjacent layers get a single via; Metal3
# rungs crossing Metal2/Metal4 are true perpendicular intersections).
#
# If the strap layers change, sram_grid stops connecting and the SRAM power
# floats silently. Fail loudly instead.
# ---------------------------------------------------------------------------
if { $::env(PDN_VERTICAL_LAYER) != "Metal4" } {
    throw APPLICATION "sram_grid requires Metal4 vertical straps (SRAM obstructs Metal1-Metal3), got $::env(PDN_VERTICAL_LAYER)."
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

    # Top vertical straps. These cross the SRAMs (Metal4 is unobstructed) and
    # are what the parent vias down onto.
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) \
        -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) \
        -spacing $::env(PDN_VSPACING) \
        -starts_with POWER \
        {*}$arg_list

    # Horizontal mesh. Trimmed where the SRAMs obstruct Metal3.
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
    # gf180mcu, so these are in-direction. Trimmed at the SRAMs, which is
    # harmless -- sram_grid bridges the macro band on Metal4.
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
    # Intentionally much coarser than PDN_HPITCH/PDN_VPITCH (130): this
    # layer exists to make Metal2-Metal4 vias reliable, not to carry
    # general current, so it should stay a small fraction of Metal3's
    # routing resource. Trimmed where the SRAMs obstruct Metal3, same as
    # the old full mesh.
    set pdn_rung_layer "Metal3"
    set pdn_rung_pitch 300
    set pdn_rung_spacing [expr {($pdn_rung_pitch - 2 * $::env(PDN_HWIDTH)) / 2}]
    add_pdn_stripe \
        -grid stdcell_grid \
        -layer $pdn_rung_layer \
        -width $::env(PDN_HWIDTH) \
        -pitch $pdn_rung_pitch \
        -offset $::env(PDN_HOFFSET) \
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

    throw APPLICATION "picorv32_hello_top requires PDN_MULTILAYER: the SRAM needs a Metal3/Metal4 bridge."
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
# NOTE: picorv32_hello_top sets PDN_CORE_RING: false. This macro integrates
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

# ---------------------------------------------------------------------------
# SRAM macro grid
#
# Four instances of gf180mcu_ocd_ip_sram__sram1024x8m8wm1, in a row along the
# bottom of the die, orientation S.
#
# Matched by -cells rather than -instances: Yosys escapes the generate-block
# indices, so the DB names contain literal backslashes
# (u_ram_ss.gen_macro_ram.gen_sram\[0\].u_wrapper.u_sram_macro). These are the
# only block masters in the design, so matching on the master is equally
# precise and does not break when names change.
#
# No add_pdn_stripe here on purpose: the Metal4 straps from stdcell_grid
# already run the full die height and pass over every macro. This grid tells
# pdn to drop Via3 wherever a Metal4 stripe of net N overlaps a Metal3 power
# pin of the same net N. A Metal4 VDD stripe crossing a Metal3 VSS tab is
# harmless -- different layers, no via, no short.
#
# The Metal3 here is hardcoded, NOT $::env(PDN_HORIZONTAL_LAYER): the SRAM's
# power pins are physically drawn on Metal3 in its own LEF, regardless of
# which layer the general stdcell_grid mesh uses for its horizontal straps.
# Decoupled so PDN_HORIZONTAL_LAYER can be Metal5 without breaking this tap.
#
# WARNING: vias only form where a Metal4 stripe physically crosses a Metal3
# pin tab. The native bottom edge of the LEF (= the placed *top* edge, given
# orientation S) has a ~36.6um gap in its VSS tabs between x=187 and x=224
# (macro-relative). Verify PDN_VOFFSET does not park a VSS stripe in that
# band for any of the four macro origins. Confirm with:
# check_power_grid -net VSS
# ---------------------------------------------------------------------------
define_pdn_grid \
    -macro \
    -name sram_grid \
    -cells "gf180mcu_ocd_ip_sram__sram1024x8m8wm1" \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect \
    -grid sram_grid \
    -layers "Metal3 $::env(PDN_VERTICAL_LAYER)"
