# SRAM macros

define_pdn_grid \
    -macro \
    -cells gf180mcu_ocd_ip_sram__sram1024x8m8wm1 \
    -name sram_macros_WE \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

#add_pdn_ring -grid sram_macros_WE \
#    -layer "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)" \
#    -widths "6.0 6.0" \
#    -spacings "0.5 0.5" \
#    -core_offsets "5 5"
#    -add_connect \
#    -connect_to_pads

add_pdn_connect \
    -grid sram_macros_WE \
    -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"

add_pdn_connect \
    -grid sram_macros_WE \
    -layers "$::env(PDN_VERTICAL_LAYER) Metal3"

#add_pdn_connect \
#    -grid sram_macros_WE \
#    -layers "$::env(PDN_VERTICAL_LAYER) Metal2"

#add_global_connection -net VDD -inst_pattern .*u_sram_macro -pin_pattern VDD
#add_global_connection -net VSS -inst_pattern .*u_sram_macro -pin_pattern VSS

# Add stripes on W/E edges of SRAM
add_pdn_stripe \
    -grid sram_macros_WE \
    -layer Metal4 \
    -width 1.36 \
    -offset 0.68 \
    -spacing 0.28 \
    -pitch 513.01 \
    -starts_with POWER \
    -number_of_straps 2
# pitch is slightly narrower than width

# Since the above stripes block the top level PDN at Metal4, add some more stripes
# to improve the PDN's integrity and ensure a better connection for the macro.
add_pdn_stripe \
    -grid sram_macros_WE \
    -layer Metal4 \
    -width 4.00 \
    -offset 28.0 \
    -spacing 0.28 \
    -pitch 43.50 \
    -starts_with GROUND \
    -number_of_straps 11
# increase number of straps to cover macro (pitch * number of straps)
