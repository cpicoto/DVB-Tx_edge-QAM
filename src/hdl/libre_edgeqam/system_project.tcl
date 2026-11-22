# SPDX-License-Identifier: GPL-3.0-or-later
if {[version -short] ne "2023.1"} { error "Vivado 2023.1 is required" }
foreach key {MAIA_DIR EDGEQAM_ROOT HLS_IP_DIR} {
    if {![info exists ::env($key)]} { error "Missing $key" }
}
set maia [file normalize $::env(MAIA_DIR)]
set edgeqam [file normalize $::env(EDGEQAM_ROOT)]
set ::tezuka_hdl_dir $maia/maia-hdl/projects
set ::env(ADI_HDL_DIR) $maia/maia-hdl/adi-hdl
set ::env(REQUIRED_VIVADO_VERSION) "2023.1"
set IGNORE_VERSION_CHECK 0
source $maia/maia-hdl/adi-hdl/scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl
set p_device "xc7z020clg400-2"
set project_name libre_edgeqam
adi_project libre_edgeqam
adi_project_files libre_edgeqam [list \
    "system_top.v" "system_constr.xdc" \
    "$edgeqam/src/hdl/libre_edgeqam/clocks.xdc" \
    "$edgeqam/src/hdl/dvbt_constr.xdc" \
    "$ad_hdl_dir/library/common/ad_iobuf.v"]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set ps_xdc [get_files -quiet *system_sys_ps7_0.xdc]
if {[llength $ps_xdc]} { set_property is_enabled false $ps_xdc }
file mkdir reports
launch_runs [get_runs -filter {IS_SYNTHESIS == 1}] -jobs 4
wait_on_run synth_1
open_run synth_1
report_utilization -hierarchical -file reports/utilization-synth.rpt
report_timing_summary -file reports/timing-synth.rpt
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_utilization -hierarchical -file reports/utilization.rpt
report_timing_summary -check_timing_verbose -report_unconstrained -file reports/timing.rpt
report_clock_interaction -file reports/clock_interaction.rpt
report_cdc -file reports/cdc.rpt
report_drc -file reports/drc.rpt
foreach kind {setup hold} {
    set paths [get_timing_paths -$kind -max_paths 1]
    if {![llength $paths]} { error "No $kind timing paths; cannot certify timing" }
    set slack [get_property SLACK $paths]
    if {$slack < 0} { error "$kind timing failed: $slack ns" }
}
set timing [report_timing_summary -check_timing_verbose -report_unconstrained -return_string]
if {![string match "*All user specified timing constraints are met*" $timing]} {
    error "Timing closure not confirmed"
}
set f [open reports/timing-closed.txt w]
puts $f "Vivado [version -short]; part [get_property PART [current_project]]; setup and hold met"
close $f
write_hw_platform -fixed -force -include_bit -file libre_edgeqam.xsa
exit
