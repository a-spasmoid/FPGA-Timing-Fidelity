# ================================================================
# FYP TIMING CHARACTERIZATION PLATFORM
# CDC CONSTRAINTS
#
# safe_clk = PS FCLK0, fixed 50 MHz
# dut_clk  = dynamically reconfigured Clock Wizard output
#
# Do NOT use broad set_clock_groups -asynchronous.
# Wide bundled-data CDC paths are explicitly bounded below.
# ================================================================


# ----------------------------------------------------------------
# SAFE -> DUT BUNDLED DATA
# ----------------------------------------------------------------

set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {
        NAME =~ *u_cdc/pixels_hold_reg* ||
        NAME =~ *u_cdc/kernel_hold_reg*
    }] \
    -to [get_cells -hier -filter {
        NAME =~ *u_cdc/pixels_stage1_reg* ||
        NAME =~ *u_cdc/kernel_stage1_reg*
    }]


# ----------------------------------------------------------------
# DUT -> SAFE BUNDLED RESULT
# ----------------------------------------------------------------

set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {
        NAME =~ *u_cdc/result_hold_reg*
    }] \
    -to [get_cells -hier -filter {
        NAME =~ *u_cdc/result_out_reg*
    }]


# ----------------------------------------------------------------
# SAFE -> DUT REQUEST TOGGLE
#
# Exempt only the metastability-catching first synchronizer stage.
# ----------------------------------------------------------------

set_false_path -to \
    [get_pins {design_1_i/conv_cdc_hw_top_0/inst/u_cdc/req_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# DUT -> SAFE RESPONSE TOGGLE
#
# Exempt only the metastability-catching first synchronizer stage.
# ----------------------------------------------------------------

set_false_path -to \
    [get_pins {design_1_i/conv_cdc_hw_top_0/inst/u_cdc/resp_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# CLOCK-WIZARD LOCK MONITOR
#
# Observational only. Exempt only first synchronizer stage.
# ----------------------------------------------------------------

set_false_path -to \
    [get_pins {design_1_i/conv_cdc_hw_top_0/inst/lock_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# RESET SYNCHRONIZERS
#
# Async assertion / synchronous deassertion.
# Ignore asynchronous assertion paths to PRE.
# ----------------------------------------------------------------

set_false_path -to [get_pins {
    design_1_i/conv_cdc_hw_top_0/inst/safe_rst_pipe_reg[0]/PRE
    design_1_i/conv_cdc_hw_top_0/inst/safe_rst_pipe_reg[1]/PRE
}]

set_false_path -to [get_pins {
    design_1_i/conv_cdc_hw_top_0/inst/dut_rst_pipe_reg[0]/PRE
    design_1_i/conv_cdc_hw_top_0/inst/dut_rst_pipe_reg[1]/PRE
}]