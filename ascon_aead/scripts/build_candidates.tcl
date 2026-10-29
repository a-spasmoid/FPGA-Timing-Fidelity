# ============================================================
# ASCON TIMING-FIDELITY  -  CANDIDATE BUILD / TIMING ARCHIVE PROCEDURE
#
# Port of convolution/scripts/build_candidates.tcl (A0..A6) to the
# Ascon candidates ascon_c0 .. ascon_c4. Structure and safeguards are
# kept; only names, paths and the points listed under CHANGES differ.
#
# STATUS: written but NOT yet run in Vivado. Expect to fix small
# name/path issues on the first real run (see "FIRST-RUN CHECKLIST").
#
# Preconditions (same as the convolution flow):
#   - The Ascon Vivado project is OPEN, with block design `design_1`
#     containing the harness as module reference `ascon_cdc_hw_top_0`
#     (child OOC run design_1_ascon_cdc_hw_top_0_0_synth_1), the Clock
#     Wizard `clk_wiz_0`, and the PS/AXI-GPIO blocks.
#   - ALL FIVE candidates ascon_c0.sv .. ascon_c4.sv and the harness
#     sources are in the project (SOURCE_MGMT_MODE = All).
#   - ascon_cdc_hardened.xdc is in constrs_1.
#   - The bridge file lives INSIDE the project (copied, not referenced from
#     the git checkout), because this script rewrites it in place:
#         import_files -force [get_files *ascon_cdc_bridge.v]
#
# Usage from the Vivado Tcl console:
#   set ASCON_REPO D:/path/to/ascon-candidates
#   source $ASCON_REPO/harness/scripts/build_candidates.tcl
#   build_candidate c3
#
# The script intentionally does NOT auto-run a candidate when sourced.
#
# CHANGES vs the convolution script
#   * candidate names c0..c4, files ascon_cN.sv, instance token
#     `ascon_cN u_candidate (` in ascon_cdc_bridge.v, golden = ascon_c0
#   * paths are derived from the open project instead of hard-coded
#   * OOC xdc = ascon_cdc_ooc_4p5ns.xdc (4.5 ns is PROVISIONAL, step 7 freezes it)
#   * fyp_ref_ok also accepts a bare module name (no prefix)
#   * guard: refuse to edit a bridge that lives inside the git checkout
#   * CDC cell check (constraints/check_cdc_cells.tcl) is a hard gate
#   * wrapper guardrail limit is a variable, WRAPPER_TEFF_MAX; the
#     convolution value (4.0 ns) belonged to a 7 ns target and MUST be
#     re-derived for the Ascon target before final builds
#   * archive snapshots every harness source, both xdc files, the
#     Vivado version and part (read from the project)
#
# FIRST-RUN CHECKLIST (things I could not verify without Vivado)
#   1. include path: ascon_batch_runner.v does `include "ascon_directed.vh".
#      This script sets the sources_1 include_dirs to the folder of that file;
#      confirm the child OOC fileset sees it too (child synthesis would
#      fail with "cannot open include file" otherwise).
#   2. CHILD_NAME / CHILD_RUN / DUTCLK_NAME must equal your project names.
#   3. REF_NAME of u_candidate / u_golden after synthesis (fyp_ref_ok).
#   4. The wrapper guardrail limit (see above).
# ============================================================

if {![info exists ASCON_REPO]} {
    error "\nSet ASCON_REPO (folder containing harness/ and rtl/) before sourcing this script.\n"
}

set FYP_ROOT   [file normalize [get_property DIRECTORY [current_project]]]
set PROJ_NAME  [current_project]
set RESULTS    "$FYP_ROOT/ascon_results"

set BD_NAME      "design_1"
set HARNESS_INST "ascon_cdc_hw_top_0"
set CHILD_NAME   "${BD_NAME}_${HARNESS_INST}_0"
set CHILD_RUN    "${CHILD_NAME}_synth_1"
set DUTCLK_NAME  "clk_out1_${BD_NAME}_clk_wiz_0_0"
set BD_BITFILE   "${BD_NAME}_wrapper.bit"

set OOC_XDC       "$ASCON_REPO/harness/constraints/ascon_cdc_ooc_4p5ns.xdc"
set CDC_CHECK_TCL "$ASCON_REPO/harness/constraints/check_cdc_cells.tcl"

# Wrapper (non-candidate, dut-domain) must be clearly faster than any candidate.
# 4.000 ns is the convolution value for its 7 ns target. RE-DERIVE for Ascon (step 7):
# build once, read "Wrapper T_eff" in the archive, then set this with margin.
if {![info exists WRAPPER_TEFF_MAX]} { set WRAPPER_TEFF_MAX 4.000 }

# 1 = allow editing a bridge that sits inside ASCON_REPO (pollutes the git checkout)
if {![info exists FYP_ALLOW_IN_PLACE_EDIT]} { set FYP_ALLOW_IN_PLACE_EDIT 0 }

set CAND_LIST {c0 c1 c2 c3 c4}

proc fyp_fail {msg} {
    error "\nFYP BUILD ABORTED: $msg\n"
}

# ------------------------------------------------------------
# pure helpers (unit-testable without Vivado)
# ------------------------------------------------------------

# Vivado can uniquify / prefix a module reference. Accept the bare module name,
# a prefixed one (design_1_..._ascon_c0) and a numeric suffix (..._ascon_c0_0).
proc fyp_ref_ok {ref mod} {
    set pat [format {(^|_)%s(_[0-9]+)?$} $mod]
    return [regexp $pat $ref]
}

proc fyp_valid_cand {cand} {
    return [regexp {^c[0-4]$} $cand]
}

# Replace ONLY the candidate module token on the `ascon_cN u_candidate (` line.
# Returns {new_text count}.
proc fyp_subst_candidate {txt cand} {
    set n [regsub -all -line \
        {^([ \t]*)ascon_c[0-4]([ \t]+u_candidate[ \t]*\()} \
        $txt \
        "\\1ascon_${cand}\\2" \
        out]
    return [list $out $n]
}

# Candidate modules that must be in the synthesis closure: the golden c0 plus the candidate.
proc fyp_expected_closure {cand} {
    if {$cand eq "c0"} { return {c0} }
    return [lsort [list c0 $cand]]
}

proc fyp_closure_from_files {files} {
    set found {}
    foreach f $files {
        if {[regexp {/ascon_(c[0-4])\.sv$} $f -> id]} { lappend found $id }
    }
    return [lsort -unique $found]
}

proc fyp_one_file {pattern what} {
    set hits [get_files -quiet $pattern]
    if {[llength $hits] != 1} {
        fyp_fail "Expected exactly one $what in the project (pattern $pattern), found [llength $hits]"
    }
    return [lindex $hits 0]
}

# ------------------------------------------------------------
proc fyp_switch_candidate {cand} {
    global FYP_ALLOW_IN_PLACE_EDIT ASCON_REPO

    if {![fyp_valid_cand $cand]} {
        fyp_fail "Invalid candidate '$cand' (expected c0..c4)"
    }

    puts "\n============================================================"
    puts " SWITCHING TO $cand"
    puts "============================================================"

    set bridge_obj [fyp_one_file *ascon_cdc_bridge.v "ascon_cdc_bridge.v"]
    set BRIDGE [file normalize [get_property NAME $bridge_obj]]

    if {!$FYP_ALLOW_IN_PLACE_EDIT} {
        set repo [file normalize $ASCON_REPO]
        if {[string first $repo $BRIDGE] == 0} {
            fyp_fail "The bridge ($BRIDGE) is inside the git checkout ($repo).\nThis script edits it in place. Copy it into the project first:\n  import_files -force \[get_files *ascon_cdc_bridge.v\]\n(or set FYP_ALLOW_IN_PLACE_EDIT 1 to accept a modified checkout)."
        }
    }

    # --------------------------------------------------------
    # Edit only the u_candidate module token
    # --------------------------------------------------------
    set fh [open $BRIDGE r]
    set txt [read $fh]
    close $fh

    lassign [fyp_subst_candidate $txt $cand] txt n

    if {$n != 1} {
        fyp_fail "Expected exactly 1 candidate substitution, got $n"
    }

    set fh [open $BRIDGE w]
    puts -nonewline $fh $txt
    close $fh

    # --------------------------------------------------------
    # CRITICAL: force Vivado to reread externally edited bridge
    # --------------------------------------------------------
    set old_type [get_property FILE_TYPE $bridge_obj]
    set old_lib  [get_property LIBRARY $bridge_obj]
    set old_used [get_property USED_IN $bridge_obj]

    remove_files -fileset sources_1 $bridge_obj
    add_files -fileset sources_1 -norecurse $BRIDGE

    set bridge_obj [get_files -quiet $BRIDGE]

    set_property FILE_TYPE $old_type $bridge_obj
    set_property LIBRARY   $old_lib  $bridge_obj
    set_property USED_IN   $old_used $bridge_obj

    # `include "ascon_directed.vh" must be resolvable
    set vh [get_files -quiet *ascon_directed.vh]
    if {$vh eq ""} { fyp_fail "ascon_directed.vh is not in the project" }
    set_property FILE_TYPE {Verilog Header} $vh
    set_property include_dirs [list [file dirname [get_property NAME $vh]]] [get_filesets sources_1]

    update_compile_order -force_gui -fileset sources_1

    # --------------------------------------------------------
    # Verify MAIN source closure before touching module ref
    # --------------------------------------------------------
    set deps [get_files \
        -quiet \
        -compile_order sources \
        -used_in synthesis \
        -of_objects [get_filesets sources_1]]

    set found    [fyp_closure_from_files $deps]
    set expected [fyp_expected_closure $cand]

    puts "Main candidate modules = $found"
    puts "Expected               = $expected"

    if {$found eq {}} {
        # The block design is synthesised out-of-context per IP, so the module
        # reference's RTL is not part of the parent compile order any more.
        # Check instead that every expected candidate file is in the project
        # EXACTLY once and that the bridge instantiates the requested candidate.
        # (The child run's real closure is verified in fyp_rebuild_child_ooc.)
        puts "Main compile order has no candidate RTL (module-reference / OOC mode)."
        foreach id $expected {
            set hits [get_files -quiet -of_objects [get_filesets sources_1] */ascon_${id}.sv]
            if {[llength $hits] != 1} {
                fyp_fail "ascon_${id}.sv must be in sources_1 exactly once, found [llength $hits]:\n  [join $hits \n\ \ ]"
            }
        }
        set fh [open $BRIDGE r]; set btxt [read $fh]; close $fh
        if {![regexp -line "^\[ \t\]*ascon_${cand}\[ \t\]+u_candidate\[ \t\]*\\(" $btxt]} {
            fyp_fail "bridge does not instantiate ascon_$cand as u_candidate"
        }
        puts "MAIN SOURCE CLOSURE: PASS (module-reference mode)"
        return
    }

    if {$found ne $expected} {
        fyp_fail "Main source closure mismatch"
    }

    puts "MAIN SOURCE CLOSURE: PASS"
}

proc fyp_rebuild_child_ooc {cand} {
    global CHILD_NAME CHILD_RUN OOC_XDC BD_NAME

    puts "\n=== REFRESH MODULE REFERENCE ==="

    update_module_reference $CHILD_NAME

    set ooc_tail [file tail $OOC_XDC]

    # --------------------------------------------------------
    # update_module_reference moves our OOC XDC out of child.
    # Remove any migrated copies from normal project filesets.
    # --------------------------------------------------------
    foreach fsname {sources_1 constrs_1} {
        set fs [get_filesets -quiet $fsname]

        if {$fs ne ""} {
            set hits [get_files -quiet \
                -of_objects $fs \
                *$ooc_tail]

            if {$hits ne ""} {
                puts "Removing migrated OOC XDC from $fsname"
                remove_files -fileset $fs $hits
            }
        }
    }

    # --------------------------------------------------------
    # Regenerate module-reference state through parent BD
    # --------------------------------------------------------
    set bd [get_files -quiet *${BD_NAME}.bd]

    if {$bd eq ""} {
        fyp_fail "${BD_NAME}.bd not found"
    }

    generate_target all $bd

    # create_ip_run may mention already-existing unrelated runs.
    # What matters is that our child run exists afterwards.
    catch {create_ip_run $bd} create_msg
    puts "create_ip_run: $create_msg"

    if {[get_runs -quiet $CHILD_RUN] eq ""} {
        fyp_fail "Child OOC run was not recreated"
    }

    set oocfs [get_filesets -quiet $CHILD_NAME]

    if {$oocfs eq ""} {
        fyp_fail "Child OOC fileset was not recreated"
    }

    # the child fileset needs the include dir as well (ascon_directed.vh)
    set vh [get_files -quiet *ascon_directed.vh]
    if {$vh ne ""} {
        catch {set_property include_dirs [list [file dirname [get_property NAME $vh]]] $oocfs}
    }

    # --------------------------------------------------------
    # Verify NATURAL child RTL closure before adding XDC
    # --------------------------------------------------------
    set deps [get_files \
        -quiet \
        -compile_order sources \
        -used_in synthesis \
        -of_objects $oocfs]

    set found    [fyp_closure_from_files $deps]
    set expected [fyp_expected_closure $cand]

    puts "Child candidate modules = $found"
    puts "Expected                = $expected"

    if {$found ne $expected} {
        fyp_fail "Child OOC source closure mismatch"
    }

    # CDC XDC must NOT be in child OOC fileset
    if {[get_files -quiet \
        -of_objects $oocfs \
        *ascon_cdc_hardened.xdc] ne ""} {
        fyp_fail "ascon_cdc_hardened.xdc leaked into child OOC fileset"
    }

    # --------------------------------------------------------
    # Reattach ONLY OOC XDC
    # --------------------------------------------------------
    add_files -fileset $oocfs -norecurse $OOC_XDC

    set ooc_obj [get_files -quiet \
        -of_objects $oocfs \
        *$ooc_tail]

    if {$ooc_obj eq ""} {
        fyp_fail "Failed to attach OOC XDC"
    }

    set_property USED_IN {synthesis out_of_context} $ooc_obj

    # Global OOC leak must remain absent
    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *$ooc_tail] ne ""} {
        fyp_fail "OOC XDC leaked into global constrs_1"
    }

    # Global CDC constraint must remain present
    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *ascon_cdc_hardened.xdc] eq ""} {
        fyp_fail "ascon_cdc_hardened.xdc disappeared from constrs_1"
    }

    puts "CHILD OOC CLOSURE/CONSTRAINTS: PASS"
}

proc fyp_synth_child {cand} {
    global CHILD_RUN

    puts "\n=== CHILD OOC SYNTHESIS: $cand ==="

    reset_run $CHILD_RUN
    launch_runs $CHILD_RUN -jobs 2
    wait_on_run $CHILD_RUN

    set status [get_property STATUS [get_runs $CHILD_RUN]]
    puts "Child status = $status"

    if {![string match "*Complete*" $status]} {
        fyp_fail "Child OOC synthesis failed"
    }

    open_run $CHILD_RUN

    set cand_cell [get_cells -hier -quiet *u_candidate]
    set gold_cell [get_cells -hier -quiet *u_golden]

    if {$cand_cell eq "" || $gold_cell eq ""} {
        fyp_fail "Candidate/golden hierarchy missing after child synth"
    }

    set cand_ref [get_property REF_NAME $cand_cell]
    set gold_ref [get_property REF_NAME $gold_cell]

    puts "Candidate REF = $cand_ref"
    puts "Golden REF    = $gold_ref"

    if {![fyp_ref_ok $cand_ref ascon_$cand]} {
        fyp_fail "Wrong candidate REF: $cand_ref"
    }

    if {![fyp_ref_ok $gold_ref ascon_c0]} {
        fyp_fail "Wrong golden REF: $gold_ref"
    }

    close_design

    puts "CHILD SYNTHESIS IDENTITY: PASS"
}

proc fyp_full_build {cand} {
    global OOC_XDC CDC_CHECK_TCL

    puts "\n=== FULL BUILD: $cand ==="

    catch {close_design}

    reset_run synth_1
    reset_run impl_1

    # --------------------------------------------------------
    # Main synthesis
    # --------------------------------------------------------
    launch_runs synth_1 -jobs 2
    wait_on_run synth_1

    set sstatus [get_property STATUS [get_runs synth_1]]
    puts "Main synth status = $sstatus"

    if {![string match "*Complete*" $sstatus]} {
        fyp_fail "Main synthesis failed"
    }

    open_run synth_1

    set cand_ref [get_property REF_NAME \
        [get_cells -hier -quiet *u_candidate]]

    set gold_ref [get_property REF_NAME \
        [get_cells -hier -quiet *u_golden]]

    puts "Full candidate REF = $cand_ref"
    puts "Full golden REF    = $gold_ref"

    if {![fyp_ref_ok $cand_ref ascon_$cand]} {
        fyp_fail "Wrong candidate in full synthesized design"
    }

    if {![fyp_ref_ok $gold_ref ascon_c0]} {
        fyp_fail "Wrong golden in full synthesized design"
    }

    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *[file tail $OOC_XDC]] ne ""} {
        fyp_fail "OOC XDC leaked into full top"
    }

    # --------------------------------------------------------
    # CDC constraints must have matched real cells/pins
    # --------------------------------------------------------
    uplevel #0 [list source $CDC_CHECK_TCL]
    if {$::bad != 0} {
        fyp_fail "CDC cell check failed ($::bad problems); constraints would silently not apply"
    }

    close_design

    # --------------------------------------------------------
    # Implementation through bitstream
    # --------------------------------------------------------
    launch_runs impl_1 -to_step write_bitstream -jobs 2
    wait_on_run impl_1

    set istatus [get_property STATUS [get_runs impl_1]]
    puts "Implementation status = $istatus"

    if {![string match "*write_bitstream Complete*" $istatus]} {
        fyp_fail "Implementation/bitstream did not complete"
    }

    open_run impl_1

    puts "FULL IMPLEMENTATION: COMPLETE"
}

proc fyp_measure_and_archive {cand} {
    global DUTCLK_NAME RESULTS FYP_ROOT OOC_XDC BD_BITFILE ASCON_REPO WRAPPER_TEFF_MAX

    puts "\n=== POST-ROUTE CLASSIFICATION: $cand ==="

    set dutclk [get_clocks -quiet $DUTCLK_NAME]

    # Vivado numbers the generated clock name (..._0, ..._1) depending on
    # how often the BD was regenerated; fall back to the clk_wiz output clock.
    if {$dutclk eq ""} {
        set dutclk [get_clocks -quiet "clk_out1_${::BD_NAME}_clk_wiz_0*"]
        if {[llength $dutclk] > 1} {
            fyp_fail "DUT clock name ambiguous: $dutclk"
        }
    }

    # last resort: the clock that actually reaches the candidate registers
    if {$dutclk eq ""} {
        set cr [get_cells -quiet -hier -filter {NAME =~ *u_candidate/* && IS_SEQUENTIAL}]
        set pins [get_pins -quiet -of_objects $cr -filter {REF_PIN_NAME == C}]
        if {$pins ne ""} {
            set dutclk [lsort -unique [get_clocks -quiet -of_objects $pins]]
        }
        if {[llength $dutclk] > 1} {
            fyp_fail "DUT clock ambiguous at candidate registers: $dutclk"
        }
    }

    if {$dutclk eq ""} {
        puts "clocks present: [get_clocks -quiet *]"
        fyp_fail "DUT clock not found"
    }

    set Tclk [expr {double([get_property PERIOD $dutclk])}]

    set dutregs [all_registers -clock $dutclk]

    set candregs [filter $dutregs {
        NAME =~ */u_candidate/*
    }]

    set resetregs [filter $dutregs {
        NAME =~ *dut_rst_pipe_reg*
    }]

    set wrapper_regs [filter $dutregs {
        NAME !~ */u_candidate/* &&
        NAME !~ *dut_rst_pipe_reg*
    }]

    puts "Tclk      = $Tclk"
    puts "DUT regs  = [llength $dutregs]"
    puts "Candidate = [llength $candregs]"
    puts "Wrapper   = [llength $wrapper_regs]"
    puts "Reset     = [llength $resetregs]"

    # --------------------------------------------------------
    # Candidate timing classes
    # candidate-launched covers:
    #   candidate -> candidate
    #   candidate -> wrapper
    #
    # wrapper -> candidate checked separately.
    # --------------------------------------------------------
    set p_cand [get_timing_paths \
        -from $candregs \
        -to $dutregs \
        -delay_type max \
        -max_paths 1 \
        -sort_by slack]

    set p_in [get_timing_paths \
        -from $wrapper_regs \
        -to $candregs \
        -delay_type max \
        -max_paths 1 \
        -sort_by slack]

    if {[llength $p_cand] == 0} {
        fyp_fail "No candidate-launched timing path found"
    }

    set slack_cand [expr {double([get_property SLACK [lindex $p_cand 0]])}]

    if {[llength $p_in] > 0} {
        set slack_in [expr {double([get_property SLACK [lindex $p_in 0]])}]
    } else {
        set slack_in 1.0e9
    }

    set cand_wns [expr {$slack_cand < $slack_in ? $slack_cand : $slack_in}]
    set Teda [expr {$Tclk - $cand_wns}]

    # --------------------------------------------------------
    # Pure wrapper apparatus guardrail
    # --------------------------------------------------------
    set p_wrap [get_timing_paths \
        -from $wrapper_regs \
        -to $wrapper_regs \
        -delay_type max \
        -max_paths 1 \
        -sort_by slack]

    if {[llength $p_wrap] == 0} {
        fyp_fail "No wrapper-only path found"
    }

    set wrapper_slack [expr {double([get_property SLACK [lindex $p_wrap 0]])}]
    set wrapper_teff  [expr {$Tclk - $wrapper_slack}]

    # --------------------------------------------------------
    # Async reset recovery/removal
    # --------------------------------------------------------
    set p_rec [get_timing_paths \
        -group **async_default** \
        -delay_type max \
        -max_paths 1 \
        -sort_by slack]

    set p_rem [get_timing_paths \
        -group **async_default** \
        -delay_type min \
        -max_paths 1 \
        -sort_by slack]

    if {[llength $p_rec] == 0 || [llength $p_rem] == 0} {
        fyp_fail "Async recovery/removal paths missing"
    }

    set rec_slack [expr {double([get_property SLACK [lindex $p_rec 0]])}]
    set rem_slack [expr {double([get_property SLACK [lindex $p_rem 0]])}]

    puts ""
    puts "Candidate-launched slack = $slack_cand ns"
    puts "Wrapper->candidate slack = $slack_in ns"
    puts "Candidate WNS            = $cand_wns ns"
    puts "T_EDA                    = $Teda ns"
    puts "Wrapper slack            = $wrapper_slack ns"
    puts "Wrapper T_eff            = $wrapper_teff ns   (limit $WRAPPER_TEFF_MAX)"
    puts "Recovery slack           = $rec_slack ns"
    puts "Removal slack            = $rem_slack ns"

    # --------------------------------------------------------
    # Hard validity criteria
    # --------------------------------------------------------
    if {$wrapper_teff > $WRAPPER_TEFF_MAX} {
        puts "\n--- worst wrapper-only paths (guardrail diagnostics) ---"
        puts [report_timing -from $wrapper_regs -to $wrapper_regs -delay_type max \
            -max_paths 3 -sort_by slack -return_string]
        fyp_fail "$cand wrapper guardrail failed: T_eff=$wrapper_teff ns (limit $WRAPPER_TEFF_MAX)"
    }

    if {$rec_slack <= 0.0} {
        fyp_fail "$cand recovery timing failed: $rec_slack ns"
    }

    if {$rem_slack <= 0.0} {
        fyp_fail "$cand removal timing failed: $rem_slack ns"
    }

    # --------------------------------------------------------
    # Archive
    # --------------------------------------------------------
    set out "$RESULTS/$cand"
    file mkdir $out

    report_timing_summary \
        -delay_type max \
        -max_paths 50 \
        -file "$out/${cand}_timing_summary.rpt"

    report_utilization \
        -file "$out/${cand}_utilization.rpt"

    report_timing \
        -from $candregs \
        -to $dutregs \
        -delay_type max \
        -max_paths 20 \
        -sort_by slack \
        -path_type full \
        -file "$out/${cand}_candidate_launched.rpt"

    report_timing \
        -from $wrapper_regs \
        -to $candregs \
        -delay_type max \
        -max_paths 20 \
        -sort_by slack \
        -path_type full \
        -file "$out/${cand}_wrapper_to_candidate.rpt"

    report_timing \
        -from $wrapper_regs \
        -to $wrapper_regs \
        -delay_type max \
        -max_paths 20 \
        -sort_by slack \
        -path_type full \
        -file "$out/${cand}_wrapper_guardrail.rpt"

    report_timing \
        -group **async_default** \
        -delay_type max \
        -max_paths 5 \
        -sort_by slack \
        -path_type full \
        -file "$out/${cand}_reset_recovery.rpt"

    report_timing \
        -group **async_default** \
        -delay_type min \
        -max_paths 5 \
        -sort_by slack \
        -path_type full \
        -file "$out/${cand}_reset_removal.rpt"

    write_checkpoint -force "$out/${cand}_routed.dcp"

    set impl_dir [get_property DIRECTORY [get_runs impl_1]]
    file copy -force "$impl_dir/$BD_BITFILE" "$out/${cand}.bit"

    # Snapshot of every source used for this bitstream (candidate, golden, harness, constraints)
    file mkdir "$out/source_snapshot"
    foreach pat [list \
        *ascon_${cand}.sv *ascon_c0.sv \
        *ascon_cdc_hw_top.v *ascon_cdc_bridge.v *ascon_batch_runner.v \
        *ascon_txn_seq.v *ascon_txn_cap.v *ascon_directed.vh \
        *ascon_cdc_hardened.xdc] {
        foreach f [get_files -quiet $pat] {
            file copy -force [get_property NAME $f] "$out/source_snapshot/"
        }
    }
    file copy -force $OOC_XDC "$out/source_snapshot/"

    # Machine-readable-ish summary
    set mf [open "$out/${cand}_metadata.txt" w]

    puts $mf "candidate=ascon_$cand"
    puts $mf "vivado=[version -short]"
    puts $mf "device=[get_property PART [current_project]]"
    puts $mf "nominal_period_ns=$Tclk"
    puts $mf "candidate_launched_slack_ns=$slack_cand"
    puts $mf "wrapper_to_candidate_slack_ns=$slack_in"
    puts $mf "candidate_wns_ns=$cand_wns"
    puts $mf "T_EDA_ns=$Teda"
    puts $mf "wrapper_slack_ns=$wrapper_slack"
    puts $mf "wrapper_Teff_ns=$wrapper_teff"
    puts $mf "wrapper_Teff_limit_ns=$WRAPPER_TEFF_MAX"
    puts $mf "recovery_slack_ns=$rec_slack"
    puts $mf "removal_slack_ns=$rem_slack"
    puts $mf "wrapper_guardrail_pass=1"
    puts $mf "reset_checks_pass=1"
    puts $mf "cdc_cell_check_pass=1"

    close $mf

    puts "\n============================================================"
    puts "$cand VALID AND ARCHIVED"
    puts "T_EDA             = [format %.3f $Teda] ns"
    puts "Candidate WNS     = [format %.3f $cand_wns] ns"
    puts "Wrapper T_eff     = [format %.3f $wrapper_teff] ns"
    puts "Recovery slack    = [format %.3f $rec_slack] ns"
    puts "Removal slack     = [format %.3f $rem_slack] ns"
    puts "Archive           = $out"
    puts "============================================================"
}

proc build_candidate {cand} {
    catch {close_design}

    fyp_switch_candidate $cand
    fyp_rebuild_child_ooc $cand
    fyp_synth_child $cand
    fyp_full_build $cand
    fyp_measure_and_archive $cand
}
