# SPDX-License-Identifier: GPL-3.0-or-later
# External reference clocks are retained for the upstream VCTCXO controller.
create_clock -name libre_vctcxo -period 25 [get_ports CLK_40MHz_FPGA]
create_clock -name libre_ref10 -period 100 [get_ports CLKIN_10MHz]
# CDC inside dvbt_bridge uses XPM FIFOs and explicitly constrained synchronizers.
# Do not blanket-exempt the AD9361 or HLS datapath from timing analysis.
