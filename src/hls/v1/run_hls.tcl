# SPDX-License-Identifier: GPL-3.0-or-later
# Run from a separate build directory; never reset a source-tree project.
set here [file dirname [file normalize [info script]]]
if {[info exists ::env(HLS_SOURCE_DIR)]} {
    set here [file normalize $::env(HLS_SOURCE_DIR)]
}
set step [expr {[info exists ::env(STEP)] ? $::env(STEP) : "export"}]
if {$step ni {csim export}} { error "STEP must be csim or export" }
open_project -reset dvbt_v1
set_top dvbt_mod
add_files $here/dvbt_mod.cpp
add_files -tb $here/tb.cpp
open_solution -reset sol1 -flow_target vivado
set_part xc7z020clg400-2
create_clock -period 10 -name default
set_clock_uncertainty 1.5
config_rtl -reset all
config_export -format ip_catalog -vendor edgeqam -library libre -version 1.0 -ipname dvbt_mod_v1
if {$step eq "csim"} {
    foreach key {TS_INPUT REFERENCE_CF32 NSYM} {
        if {![info exists ::env($key)]} { error "Missing $key for reference C simulation" }
    }
    if {$::env(NSYM) < 150} { error "At least 150 symbols required" }
    set args [list $::env(TS_INPUT) $::env(REFERENCE_CF32) $::env(NSYM)]
    if {[info exists ::env(REFERENCE_CS16)]} {
        lappend args $::env(REFERENCE_CS16)
    }
    csim_design -clean -argv $args
} else {
    csynth_design
    export_design -rtl verilog -format ip_catalog
}
exit
