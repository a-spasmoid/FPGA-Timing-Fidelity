# OOC synthesis constraints for ascon_cdc_hw_top  (adapted from conv_cdc_ooc_7ns.xdc)
#
# dut_clk period = 4.500 ns is PROVISIONAL: it comes from the quick screening of the bare
# cores (c0 and c3 close near 4.5 ns). The handoff says NOT to reuse the convolution 7 ns;
# the common Ascon target is chosen and frozen in step 7. To change it, copy this file to
# ascon_cdc_ooc_<T>ns.xdc and edit the single dut_clk period below.

create_clock -name safe_clk_ooc \
    -period 20.000 \
    [get_ports safe_clk]

create_clock -name dut_clk_ooc \
    -period 4.500 \
    [get_ports dut_clk]

# During OOC synthesis, do not optimize arbitrary safe<->DUT
# crossings as synchronous paths.
# The real top-level ascon_cdc_hardened.xdc supplies the bundled-data
# max-delay constraints during implementation.
set_clock_groups -asynchronous \
    -group [get_clocks safe_clk_ooc] \
    -group [get_clocks dut_clk_ooc]
