# SPDX-License-Identifier: GPL-3.0-or-later
# xsct create_fsbl.tcl libre_edgeqam.xsa <workspace>
set xsa [file normalize [lindex $argv 0]]
set workspace [file normalize [lindex $argv 1]]
if {![file isfile $xsa]} { error "Missing implemented LibreSDR XSA" }
setws $workspace
app create -name fsbl -hw $xsa -proc ps7_cortexa9_0 -os standalone -lang C -template {Zynq FSBL}
app config -name fsbl -set build-config release
app build -name fsbl
exit
