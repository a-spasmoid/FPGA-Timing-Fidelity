# check_cdc_cells.tcl : fail loudly if a CDC constraint would silently match nothing.
# Run in Vivado on an open SYNTHESIZED (or implemented) design:
#     open_run synth_1 ; source constraints/check_cdc_cells.tcl
# An XDC filter that matches no cells only produces a warning, so a renamed register would
# leave the bundled data unconstrained without any error. This makes that visible.
#
# Works on a standalone ascon_cdc_hw_top AND inside the block design. The absolute
# design_1_i/ascon_cdc_hw_top_0/... pin paths used by ascon_cdc_hardened.xdc are only
# checked when design_1_i exists.
set bad 0

proc chk {label cells min} {
  global bad
  set n [llength $cells]
  if {$n < $min} { puts "FAIL  $label : matched $n (expected >= $min)"; incr bad } \
  else           { puts "ok    $label : matched $n" }
}

# Bits of the 651-bit txn bundle that are constant 0 in this workload (ad_bytes[4] = txn[9],
# pt2_bytes[4] = txn[4]; byte counts never exceed 15) and are legitimately removed as constants.
set expected_missing {4 9}

proc chk_bundle {label reg width} {
  global bad expected_missing
  set cells [get_cells -quiet -hier -filter "NAME =~ *u_cdc/${reg}_reg*"]
  set have {}
  foreach c $cells {
    if {[regexp {\[(\d+)\]$} [get_property NAME $c] -> i]} { lappend have $i }
  }
  set missing {}
  for {set i 0} {$i < $width} {incr i} { if {[lsearch -exact $have $i] < 0} { lappend missing $i } }
  if {$missing eq $expected_missing || ($expected_missing eq {} && $missing eq {})} {
    puts "ok    $label : [llength $have]/$width bits present, missing {$missing}"
  } else {
    puts "FAIL  $label : [llength $have]/$width bits present, missing {$missing} (expected missing {$expected_missing})"
    incr bad
  }
}

set expected_missing {4 9}
chk_bundle "txn_hold_reg   (651-bit bundle)" txn_hold   651
chk_bundle "txn_stage1_reg (651-bit bundle)" txn_stage1 651
set expected_missing {}
chk_bundle "result_hold_reg (384-bit result)" result_hold 384
chk_bundle "result_out_reg  (384-bit result)" result_out  384

# synchronizer / reset flops by relative name (any design).
# NB: '[' is a glob character inside -filter patterns, so select by name without brackets
# and test the bit index in Tcl.
proc chk_pin {label namepat pin idx} {
  set rx "_reg\\\[${idx}\\\]/${pin}\$"
  set hits {}
  foreach p [get_pins -quiet -hier -filter "NAME =~ $namepat"] {
    if {[regexp $rx [get_property NAME $p]]} { lappend hits $p }
  }
  chk "pin $label (relative)" $hits 1
}
chk_pin req_sync_pipe\[0\]/D    *u_cdc/req_sync_pipe_reg*/D   D   0
chk_pin resp_sync_pipe\[0\]/D   *u_cdc/resp_sync_pipe_reg*/D  D   0
chk_pin lock_sync_pipe\[0\]/D   *lock_sync_pipe_reg*/D        D   0
chk_pin safe_rst_pipe\[0\]/PRE  *safe_rst_pipe_reg*/PRE      PRE 0
chk_pin safe_rst_pipe\[1\]/PRE  *safe_rst_pipe_reg*/PRE      PRE 1
chk_pin dut_rst_pipe\[0\]/PRE   *dut_rst_pipe_reg*/PRE       PRE 0
chk_pin dut_rst_pipe\[1\]/PRE   *dut_rst_pipe_reg*/PRE       PRE 1

# absolute paths used by ascon_cdc_hardened.xdc: only meaningful inside the block design
if {[llength [get_cells -quiet design_1_i]] > 0} {
  foreach p {
    design_1_i/ascon_cdc_hw_top_0/inst/u_cdc/req_sync_pipe_reg[0]/D
    design_1_i/ascon_cdc_hw_top_0/inst/u_cdc/resp_sync_pipe_reg[0]/D
    design_1_i/ascon_cdc_hw_top_0/inst/lock_sync_pipe_reg[0]/D
    design_1_i/ascon_cdc_hw_top_0/inst/safe_rst_pipe_reg[0]/PRE
    design_1_i/ascon_cdc_hw_top_0/inst/safe_rst_pipe_reg[1]/PRE
    design_1_i/ascon_cdc_hw_top_0/inst/dut_rst_pipe_reg[0]/PRE
    design_1_i/ascon_cdc_hw_top_0/inst/dut_rst_pipe_reg[1]/PRE
  } { chk "abs $p" [get_pins -quiet $p] 1 }
} else {
  puts "skip  absolute design_1_i/ascon_cdc_hw_top_0 paths (no design_1_i: standalone top)"
}

# the synchronizer pipes must really be separate flops, not shift-register primitives
set srl [get_cells -quiet -hier -filter {REF_NAME =~ SRL* && NAME =~ *sync_pipe*}]
if {[llength $srl] > 0} { puts "FAIL  synchronizer mapped to SRL"; incr bad } else { puts "ok    no SRL in sync pipes" }

puts [expr {$bad ? "CDC CELL CHECK: FAIL ($bad)" : "CDC CELL CHECK: PASS"}]
