# OOC synthesis constraints for conv_cdc_hw_top

create_clock -name safe_clk_ooc \
    -period 20.000 \
    [get_ports safe_clk]

create_clock -name dut_clk_ooc \
    -period 7.000 \
    [get_ports dut_clk]

# During OOC synthesis, do not optimize arbitrary safe<->DUT
# crossings as synchronous paths.
# The real top-level cdc_hardened.xdc supplies the bundled-data
# max-delay constraints during implementation.
set_clock_groups -asynchronous \
    -group [get_clocks safe_clk_ooc] \
    -group [get_clocks dut_clk_ooc]