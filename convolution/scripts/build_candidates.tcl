# ============================================================
# FYP FINAL CANDIDATE BUILD / TIMING ARCHIVE PROCEDURE
#
# Reconstructed from the proven Vivado 2026.1 console flow used
# for the final A0-A6 builds. The only functional change from the
# captured A2->A4-era procedure is the later proven REF_NAME
# matching fix (fyp_ref_ok), required because Vivado may uniquify
# a module reference, e.g. ..._A0_0 instead of ..._A0.
#
# Preconditions:
#   - Open C:/viv/b/fyp_timing_final/fyp_timing_final.xpr
#   - Project source management is the same as the final builds
#     (SOURCE_MGMT_MODE = All)
#
# Usage from the Vivado Tcl console:
#   source C:/path/to/build_candidates.tcl
#   build_candidate A2
#
# The script intentionally does NOT auto-run a candidate when sourced.
# ============================================================

set FYP_ROOT   "C:/viv/b/fyp_timing_final"
set SRC_DIR    "$FYP_ROOT/fyp_timing_final.srcs/sources_1/new"
set CONSTR_DIR "$FYP_ROOT/fyp_timing_final.srcs/constrs_1/new"
set RESULTS    "$FYP_ROOT/final_results"
set BRIDGE     "$SRC_DIR/conv_cdc_bridge.v"
set OOC_XDC    "$CONSTR_DIR/conv_cdc_ooc_7ns.xdc"

set CHILD_NAME "design_1_conv_cdc_hw_top_0_0"
set CHILD_RUN  "${CHILD_NAME}_synth_1"
set DUTCLK_NAME "clk_out1_design_1_clk_wiz_0_0"

proc fyp_fail {msg} {
    error "\nFYP BUILD ABORTED: $msg\n"
}

# Vivado can uniquify a module reference when candidate and golden
# use the same underlying RTL module (notably A0 -> ..._A0_0).
# Accept either _Ax or _Ax_<numeric suffix>.
proc fyp_ref_ok {ref mod} {
    set pat [format {_%s(_[0-9]+)?$} $mod]
    return [regexp $pat $ref]
}

proc fyp_switch_candidate {cand} {
    global BRIDGE

    if {![regexp {^A[0-6]$} $cand]} {
        fyp_fail "Invalid candidate '$cand'"
    }

    puts "\n============================================================"
    puts " SWITCHING TO $cand"
    puts "============================================================"

    # --------------------------------------------------------
    # Edit only the u_candidate module token
    # --------------------------------------------------------
    set fh [open $BRIDGE r]
    set txt [read $fh]
    close $fh

    set n [regsub -all -line \
        {^([ \t]*)A[0-6]([ \t]+u_candidate[ \t]*\()} \
        $txt \
        "\\1${cand}\\2" \
        txt]

    if {$n != 1} {
        fyp_fail "Expected exactly 1 candidate substitution, got $n"
    }

    set fh [open $BRIDGE w]
    puts -nonewline $fh $txt
    close $fh

    # --------------------------------------------------------
    # CRITICAL: force Vivado to reread externally edited bridge
    # --------------------------------------------------------
    set bridge_obj [get_files -quiet $BRIDGE]

    if {$bridge_obj eq ""} {
        fyp_fail "Bridge source object not found"
    }

    set old_type [get_property FILE_TYPE $bridge_obj]
    set old_lib  [get_property LIBRARY $bridge_obj]
    set old_used [get_property USED_IN $bridge_obj]

    remove_files -fileset sources_1 $bridge_obj
    add_files -fileset sources_1 -norecurse $BRIDGE

    set bridge_obj [get_files -quiet $BRIDGE]

    set_property FILE_TYPE $old_type $bridge_obj
    set_property LIBRARY   $old_lib  $bridge_obj
    set_property USED_IN   $old_used $bridge_obj

    update_compile_order -force_gui -fileset sources_1

    # --------------------------------------------------------
    # Verify MAIN source closure before touching module ref
    # --------------------------------------------------------
    set deps [get_files \
        -quiet \
        -compile_order sources \
        -used_in synthesis \
        -of_objects [get_filesets sources_1]]

    set found {}

    foreach f $deps {
        if {[regexp {/A([0-6])\.v$} $f -> num]} {
            lappend found "A$num"
        }
    }

    set found [lsort -unique $found]

    if {$cand eq "A0"} {
        set expected {A0}
    } else {
        set expected [lsort [list A0 $cand]]
    }

    puts "Main candidate modules = $found"
    puts "Expected               = $expected"

    if {$found ne $expected} {
        fyp_fail "Main source closure mismatch"
    }

    puts "MAIN SOURCE CLOSURE: PASS"
}

proc fyp_rebuild_child_ooc {cand} {
    global CHILD_NAME CHILD_RUN OOC_XDC

    puts "\n=== REFRESH MODULE REFERENCE ==="

    update_module_reference $CHILD_NAME

    # --------------------------------------------------------
    # update_module_reference moves our OOC XDC out of child.
    # Remove any migrated copies from normal project filesets.
    # --------------------------------------------------------
    foreach fsname {sources_1 constrs_1} {
        set fs [get_filesets -quiet $fsname]

        if {$fs ne ""} {
            set hits [get_files -quiet \
                -of_objects $fs \
                *conv_cdc_ooc_7ns.xdc]

            if {$hits ne ""} {
                puts "Removing migrated OOC XDC from $fsname"
                remove_files -fileset $fs $hits
            }
        }
    }

    # --------------------------------------------------------
    # Regenerate module-reference state through parent BD
    # --------------------------------------------------------
    set bd [get_files -quiet *design_1.bd]

    if {$bd eq ""} {
        fyp_fail "design_1.bd not found"
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

    # --------------------------------------------------------
    # Verify NATURAL child RTL closure before adding XDC
    # --------------------------------------------------------
    set deps [get_files \
        -quiet \
        -compile_order sources \
        -used_in synthesis \
        -of_objects $oocfs]

    set found {}

    foreach f $deps {
        if {[regexp {/A([0-6])\.v$} $f -> num]} {
            lappend found "A$num"
        }
    }

    set found [lsort -unique $found]

    if {$cand eq "A0"} {
        set expected {A0}
    } else {
        set expected [lsort [list A0 $cand]]
    }

    puts "Child candidate modules = $found"
    puts "Expected                = $expected"

    if {$found ne $expected} {
        fyp_fail "Child OOC source closure mismatch"
    }

    # CDC XDC must NOT be in child OOC fileset
    if {[get_files -quiet \
        -of_objects $oocfs \
        *cdc_hardened.xdc] ne ""} {
        fyp_fail "cdc_hardened.xdc leaked into child OOC fileset"
    }

    # --------------------------------------------------------
    # Reattach ONLY OOC XDC
    # --------------------------------------------------------
    add_files -fileset $oocfs -norecurse $OOC_XDC

    set ooc_obj [get_files -quiet \
        -of_objects $oocfs \
        *conv_cdc_ooc_7ns.xdc]

    if {$ooc_obj eq ""} {
        fyp_fail "Failed to attach OOC XDC"
    }

    set_property USED_IN {synthesis out_of_context} $ooc_obj

    # Global OOC leak must remain absent
    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *conv_cdc_ooc_7ns.xdc] ne ""} {
        fyp_fail "OOC XDC leaked into global constrs_1"
    }

    # Global CDC constraint must remain present
    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *cdc_hardened.xdc] eq ""} {
        fyp_fail "cdc_hardened.xdc disappeared from constrs_1"
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

    if {![fyp_ref_ok $cand_ref $cand]} {
        fyp_fail "Wrong candidate REF: $cand_ref"
    }

    if {![fyp_ref_ok $gold_ref A0]} {
        fyp_fail "Wrong golden REF: $gold_ref"
    }

    close_design

    puts "CHILD SYNTHESIS IDENTITY: PASS"
}

proc fyp_full_build {cand} {
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

    if {![fyp_ref_ok $cand_ref $cand]} {
        fyp_fail "Wrong candidate in full synthesized design"
    }

    if {![fyp_ref_ok $gold_ref A0]} {
        fyp_fail "Wrong golden in full synthesized design"
    }

    if {[get_files -quiet \
        -of_objects [get_filesets constrs_1] \
        *conv_cdc_ooc_7ns.xdc] ne ""} {
        fyp_fail "OOC XDC leaked into full top"
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
    global DUTCLK_NAME RESULTS FYP_ROOT SRC_DIR BRIDGE

    puts "\n=== POST-ROUTE CLASSIFICATION: $cand ==="

    set dutclk [get_clocks -quiet $DUTCLK_NAME]

    if {$dutclk eq ""} {
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
    puts "Wrapper T_eff            = $wrapper_teff ns"
    puts "Recovery slack           = $rec_slack ns"
    puts "Removal slack            = $rem_slack ns"

    # --------------------------------------------------------
    # Hard validity criteria
    # --------------------------------------------------------
    if {$wrapper_teff > 4.000} {
        fyp_fail "$cand wrapper guardrail failed: T_eff=$wrapper_teff ns"
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

    file copy -force \
        "$FYP_ROOT/fyp_timing_final.runs/impl_1/design_1_wrapper.bit" \
        "$out/${cand}.bit"

    # Snapshot the candidate RTL and bridge used for this bitstream.
    file copy -force \
        "$SRC_DIR/${cand}.v" \
        "$out/${cand}_source.v"

    file copy -force \
        $BRIDGE \
        "$out/conv_cdc_bridge.v"

    # Machine-readable-ish summary
    set mf [open "$out/${cand}_metadata.txt" w]

    puts $mf "candidate=$cand"
    puts $mf "vivado=2026.1"
    puts $mf "device=xc7z020clg400-1"
    puts $mf "nominal_period_ns=$Tclk"
    puts $mf "candidate_launched_slack_ns=$slack_cand"
    puts $mf "wrapper_to_candidate_slack_ns=$slack_in"
    puts $mf "candidate_wns_ns=$cand_wns"
    puts $mf "T_EDA_ns=$Teda"
    puts $mf "wrapper_slack_ns=$wrapper_slack"
    puts $mf "wrapper_Teff_ns=$wrapper_teff"
    puts $mf "recovery_slack_ns=$rec_slack"
    puts $mf "removal_slack_ns=$rem_slack"
    puts $mf "wrapper_guardrail_pass=1"
    puts $mf "reset_checks_pass=1"

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
