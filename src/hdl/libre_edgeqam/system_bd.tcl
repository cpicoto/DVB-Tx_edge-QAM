# SPDX-License-Identifier: GPL-3.0-or-later
# Reuse only the pinned LibreSDR PS7, ADI radio/DMA and VCTCXO infrastructure.
set_property ip_repo_paths [list \
    $ad_hdl_dir/library \
    $::tezuka_hdl_dir/common/libre-vctcxo-lock \
    [file normalize $::env(HLS_IP_DIR)]] [current_project]
update_ip_catalog -rebuild
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 ddr
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 fixed_io
set lvds 1
# DDS retained for Linux's AD9361 digital tuning; DMA-selected TX is replaced below.
set dac_dds 1
source $::tezuka_hdl_dir/boards/libre/ps7.tcl
source $::tezuka_hdl_dir/common/xilinx_ad9361.tcl
source $::tezuka_hdl_dir/boards/libre/ports.tcl
source $::tezuka_hdl_dir/common/minimal.tcl
source $::tezuka_hdl_dir/boards/libre/vcxo_ctrl.tcl

add_files -norecurse $edgeqam/src/hdl/dvbt_bridge.v
update_compile_order -fileset sources_1
create_bd_cell -type ip -vlnv edgeqam:libre:dvbt_mod_v1:1.0 dvbt_mod
create_bd_cell -type module -reference dvbt_bridge dvbt_bridge
set_property CONFIG.SINGLE_MUX 1 [get_bd_cells dvbt_bridge]
delete_bd_objs [get_bd_intf_nets -of_objects [get_bd_intf_pins axi_ad9361_dac_dma/m_axis]]
delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_ad9361_dac_fifo/din_valid_in_0]]
for {set i 0} {$i < 4} {incr i} {
    delete_bd_objs [get_bd_nets -of_objects [get_bd_pins axi_ad9361_dac_fifo/din_data_$i]]
    ad_connect util_ad9361_dac_upack/fifo_rd_data_$i dvbt_bridge/in_d$i
    ad_connect dvbt_bridge/dac_d$i axi_ad9361_dac_fifo/din_data_$i
    ad_connect dvbt_bridge/dac_valid axi_ad9361_dac_fifo/din_valid_in_$i
}
ad_connect sys_cpu_clk dvbt_bridge/s_clk
ad_connect sys_cpu_clk dvbt_mod/ap_clk
ad_connect sys_cpu_resetn dvbt_bridge/s_resetn
ad_connect dvbt_bridge/hls_rst_n dvbt_mod/ap_rst_n
ad_connect util_ad9361_divclk/clk_out dvbt_bridge/d_clk
ad_connect axi_ad9361/up_dac_gpio_out dvbt_bridge/gpio_out
ad_connect dvbt_bridge/gpio_in axi_ad9361/up_dac_gpio_in
ad_connect GND dvbt_bridge/ctl_ready
ad_connect dvbt_bridge/ts_data dvbt_mod/ts_in_TDATA
ad_connect dvbt_bridge/ts_valid dvbt_mod/ts_in_TVALID
ad_connect dvbt_mod/ts_in_TREADY dvbt_bridge/ts_ready
ad_connect dvbt_mod/iq_out_TDATA dvbt_bridge/iq_data
ad_connect dvbt_mod/iq_out_TVALID dvbt_bridge/iq_valid
ad_connect dvbt_bridge/iq_ready dvbt_mod/iq_out_TREADY
ad_connect dvbt_mod/st_ts_TDATA dvbt_bridge/stts_data
ad_connect dvbt_mod/st_ts_TVALID dvbt_bridge/stts_valid
ad_connect dvbt_bridge/stts_ready dvbt_mod/st_ts_TREADY
ad_connect dvbt_mod/st_fft_TDATA dvbt_bridge/stfft_data
ad_connect dvbt_mod/st_fft_TVALID dvbt_bridge/stfft_valid
ad_connect dvbt_bridge/stfft_ready dvbt_mod/st_fft_TREADY
ad_connect axi_ad9361_dac_dma/m_axis_data dvbt_bridge/dma_data
ad_connect axi_ad9361_dac_dma/m_axis_valid dvbt_bridge/dma_valid
ad_connect dvbt_bridge/dma_ready axi_ad9361_dac_dma/m_axis_ready
ad_connect dvbt_bridge/up_data util_ad9361_dac_upack/s_axis_data
ad_connect dvbt_bridge/up_valid util_ad9361_dac_upack/s_axis_valid
ad_connect util_ad9361_dac_upack/s_axis_ready dvbt_bridge/up_ready
ad_connect axi_ad9361_dac_fifo/din_valid_0 dvbt_bridge/dac_req
ad_connect util_ad9361_dac_upack/fifo_rd_valid dvbt_bridge/in_valid

# Addresses/interrupts come unchanged from common/xilinx_ad9361.tcl:
# ADC 0x79020000, DAC 0x79024000, RX DMA 0x7C400000 / ps-13,
# TX DMA 0x7C420000 / ps-12. No Maia, TX FIR, correction NCO or other modem.
validate_bd_design
save_bd_design
