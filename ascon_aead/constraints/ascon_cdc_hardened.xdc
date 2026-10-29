# ================================================================
# ASCON TIMING-FIDELITY PLATFORM
# CDC CONSTRAINTS  (adapted from convolution/constraints/cdc_hardened.xdc)
#
# safe_clk = PS FCLK0, fixed 50 MHz  (period 20 ns)  -> keep if your PS clock is the same
# dut_clk  = dynamically reconfigured Clock Wizard output
#
# Do NOT use broad set_clock_groups -asynchronous.
# Wide bundled-data CDC paths are explicitly bounded below.
#
# Changes vs the convolution file (signal names / widths only):
#   pixels_hold/kernel_hold -> txn_hold      (651-bit transaction bundle)
#   pixels_stage1/kernel_stage1 -> txn_stage1
#   result_hold / result_out : now 384 bits (names unchanged)
#   design_1_i/conv_cdc_hw_top_0 -> design_1_i/ascon_cdc_hw_top_0
#
# ASSUMES the block-design instance of the harness is named ascon_cdc_hw_top_0
# (the default when ascon_cdc_hw_top is added as a module reference). If yours differs,
# edit the four hierarchical pin paths below. Verify with constraints/check_cdc_cells.tcl.
#
# The 20.000 ns bounds equal the safe-clock period, as in the convolution file. The bundle
# is written by the safe domain and only consumed >= 2 safe cycles + 3 dut cycles later
# (settle_count + synchronizer), so the bound is conservative for both directions.
# ================================================================


# ----------------------------------------------------------------
# SAFE -> DUT BUNDLED DATA
# ----------------------------------------------------------------

set_max_delay -datapath_only 20.000 \
    -from [get_cells -hier -filter {
        NAME =~ *u_cdc/txn_hold_reg*
    }] \
    -to [get_cells -hier -filter {
        NAME =~ *u_cdc/txn_stage1_reg*
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
    [get_pins {design_1_i/ascon_cdc_hw_top_0/inst/u_cdc/req_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# DUT -> SAFE RESPONSE TOGGLE
#
# Exempt only the metastability-catching first synchronizer stage.
# ----------------------------------------------------------------

set_false_path -to \
    [get_pins {design_1_i/ascon_cdc_hw_top_0/inst/u_cdc/resp_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# CLOCK-WIZARD LOCK MONITOR
#
# Observational only. Exempt only first synchronizer stage.
# ----------------------------------------------------------------

set_false_path -to \
    [get_pins {design_1_i/ascon_cdc_hw_top_0/inst/lock_sync_pipe_reg[0]/D}]


# ----------------------------------------------------------------
# RESET SYNCHRONIZERS
#
# Async assertion / synchronous deassertion.
# Ignore asynchronous assertion paths to PRE.
# ----------------------------------------------------------------

set_false_path -to [get_pins {
    design_1_i/ascon_cdc_hw_top_0/inst/safe_rst_pipe_reg[0]/PRE
    design_1_i/ascon_cdc_hw_top_0/inst/safe_rst_pipe_reg[1]/PRE
}]

set_false_path -to [get_pins {
    design_1_i/ascon_cdc_hw_top_0/inst/dut_rst_pipe_reg[0]/PRE
    design_1_i/ascon_cdc_hw_top_0/inst/dut_rst_pipe_reg[1]/PRE
}]
