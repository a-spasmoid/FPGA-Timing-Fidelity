`timescale 1ns / 1ps

module conv_cdc_hw_top (
    input  wire        safe_clk,
    input  wire        dut_clk,

    // Clock Wizard lock indication.
    // Observational only; never participates in the functional CDC.
    input  wire        dut_clk_locked,

    // System-level reset from the block design.
    input  wire        system_reset,

    // AXI-GPIO control inputs
    input  wire [31:0] control_word,
    input  wire [31:0] seed_word,

    // AXI-GPIO status outputs
    output wire [31:0] status_word0,
    output wire [31:0] status_word1
);

    // ============================================================
    // CONTROL WORD
    //
    // [15:0]  batch_count
    // [16]    start_toggle
    // [18:17] workload_mode
    // [19]    software logic-reset request
    // [31:20] reserved
    // ============================================================

    wire [15:0] batch_count;
    wire        start_toggle;
    wire [1:0]  workload_mode;
    wire        sw_reset_req;

    assign batch_count    = control_word[15:0];
    assign start_toggle   = control_word[16];
    assign workload_mode  = control_word[18:17];
    assign sw_reset_req   = control_word[19];

    // ============================================================
    // COORDINATED LOGIC RESET REQUEST
    //
    // Software reset affects the measurement logic only.
    // It does NOT reset the Clock Wizard.
    //
    // system_reset may assert asynchronously.
    // Software reset is sampled in the safe domain.
    // ============================================================

    reg reset_req_q;

    always @(posedge safe_clk or posedge system_reset) begin
        if (system_reset)
            reset_req_q <= 1'b1;
        else
            reset_req_q <= sw_reset_req;
    end

    wire reset_req;

    assign reset_req = reset_req_q;

    // ============================================================
    // ASYNC ASSERT / SYNC DEASSERT RESETS
    //
    // Both domains are placed in reset together.
    //
    // Assertion does not require the destination clock.
    // Deassertion occurs synchronously in each clock domain.
    // ============================================================

    (* ASYNC_REG = "TRUE" *)
    reg [1:0] safe_rst_pipe;

    (* ASYNC_REG = "TRUE" *)
    reg [1:0] dut_rst_pipe;

    always @(posedge safe_clk or posedge reset_req) begin

        if (reset_req)
            safe_rst_pipe <= 2'b11;

        else
            safe_rst_pipe <= {
                safe_rst_pipe[0],
                1'b0
            };

    end

    always @(posedge dut_clk or posedge reset_req) begin

        if (reset_req)
            dut_rst_pipe <= 2'b11;

        else
            dut_rst_pipe <= {
                dut_rst_pipe[0],
                1'b0
            };

    end

    wire safe_rst;
    wire dut_rst;

    assign safe_rst = safe_rst_pipe[1];
    assign dut_rst  = dut_rst_pipe[1];
    
    // ============================================================
    // RUNNER / CDC SIGNALS
    // ============================================================
    
    wire [71:0] runner_pixels;
    wire [71:0] runner_kernel;
    
    wire        candidate_launch;
    wire signed [19:0] candidate_result;
    wire               candidate_done;
    
    wire        runner_busy;
    wire        done_toggle;
    
    wire [15:0] tests_run;
    wire [15:0] wrong_count;
    wire [15:0] timeout_count;
    
    wire [15:0] first_wrong_index;
    wire        first_wrong_valid;
    
    wire timeout_candidate_seen;
    wire timeout_golden_seen;

    // ============================================================
    // CLOCK-WIZARD LOCK MONITOR
    //
    // The DUT clock is deliberately varied during the experiment.
    // Frequency changes between batches may legitimately cause the
    // Clock Wizard to unlock temporarily.
    //
    // Therefore:
    //
    //   lock_live
    //       = current synchronized lock state
    //
    //   clock_fault_seen
    //       = sticky indication that lock was low while a batch
    //         was actually running
    //
    // clock_fault_seen is cleared when a new batch starts.
    //
    // This monitor is observational only. It never changes the
    // transaction protocol or resets the DUT.
    // ============================================================

    (* ASYNC_REG = "TRUE" *)
    reg [1:0] lock_sync_pipe;

    reg clock_fault_seen;

    reg start_monitor_armed;
    reg start_toggle_q;

    always @(posedge safe_clk) begin

        if (safe_rst) begin

            lock_sync_pipe <= 2'b00;

            clock_fault_seen <= 1'b0;

            start_monitor_armed <= 1'b0;
            start_toggle_q      <= 1'b0;

        end

        else begin

            // Synchronize the Clock Wizard LOCKED signal.
            lock_sync_pipe <= {
                lock_sync_pipe[0],
                dut_clk_locked
            };

            // Establish the current software-toggle level after
            // reset without interpreting it as a new batch.
            if (!start_monitor_armed) begin

                start_toggle_q      <= start_toggle;
                start_monitor_armed <= 1'b1;

                clock_fault_seen <= 1'b0;

            end

            else begin

                start_toggle_q <= start_toggle;

                // A new batch gets a fresh infrastructure-fault flag.
                if (start_toggle != start_toggle_q) begin

                    // If software starts while the Clock Wizard is
                    // already unlocked, classify that immediately.
                    clock_fault_seen <= ~lock_sync_pipe[1];

                end

                // During an active batch, any observed loss of lock
                // makes the measurement infrastructure suspect.
                else if (runner_busy && !lock_sync_pipe[1]) begin

                    clock_fault_seen <= 1'b1;

                end
            end
        end
    end

    wire lock_live;

    assign lock_live = lock_sync_pipe[1];

    // ============================================================
    // AUTONOMOUS BATCH RUNNER
    // ============================================================

    conv_batch_runner #(
        .TIMEOUT_CYCLES(1024)
    ) u_runner (
        .safe_clk               (safe_clk),
        .safe_rst               (safe_rst),

        .start_toggle           (start_toggle),
        .batch_count            (batch_count),
        .seed                   (seed_word),
        .workload_mode          (workload_mode),

        .runner_busy            (runner_busy),
        .done_toggle            (done_toggle),

        .tests_run              (tests_run),
        .wrong_count            (wrong_count),
        .timeout_count          (timeout_count),

        .first_wrong_index      (first_wrong_index),
        .first_wrong_valid      (first_wrong_valid),

        .timeout_candidate_seen (timeout_candidate_seen),
        .timeout_golden_seen    (timeout_golden_seen),

        .current_pixels         (runner_pixels),
        .current_kernel         (runner_kernel),

        // Useful internally during development, but not required
        // in the final software-visible status interface.
        .candidate_result_dbg   (),
        .expected_result_dbg    (),

        .candidate_launch       (candidate_launch),
        .candidate_result       (candidate_result),
        .candidate_done         (candidate_done)
    );

    // ============================================================
    // CDC BRIDGE + CANDIDATE DUT
    // ============================================================

    conv_cdc_bridge u_cdc (
        .safe_clk   (safe_clk),
        .dut_clk    (dut_clk),

        .safe_rst   (safe_rst),
        .dut_rst    (dut_rst),

        .launch     (candidate_launch),
        .pixels_in  (runner_pixels),
        .kernel_in  (runner_kernel),

        .result_out (candidate_result),
        .done_pulse (candidate_done)
    );

    // ============================================================
    // SOFTWARE-VISIBLE STATUS
    // ============================================================

    wire timeout_seen;

    assign timeout_seen =
        (timeout_count != 16'd0);

    // ------------------------------------------------------------
    // status_word0
    //
    // [15:0]  tests_run
    // [31:16] wrong_count
    // ------------------------------------------------------------

    assign status_word0 = {
        wrong_count,
        tests_run
    };

    // ------------------------------------------------------------
    // status_word1
    //
    // [15:0]  first_wrong_index
    // [16]    first_wrong_valid
    // [17]    timeout_seen
    // [18]    runner_busy
    // [19]    done_toggle
    // [20]    timeout_candidate_seen
    // [21]    timeout_golden_seen
    // [22]    lock_live
    // [23]    clock_fault_seen
    // [31:24] reserved = 0
    //
    // Interpretation:
    //
    // wrong result + clock_fault_seen=0
    //     -> candidate timing/computation failure
    //
    // timeout + clock_fault_seen=0
    //     -> candidate/control timing failure
    //
    // clock_fault_seen=1
    //     -> infrastructure event; discard that measurement
    // ------------------------------------------------------------

    assign status_word1 = {
        8'd0,
        clock_fault_seen,
        lock_live,
        timeout_golden_seen,
        timeout_candidate_seen,
        done_toggle,
        runner_busy,
        timeout_seen,
        first_wrong_valid,
        first_wrong_index
    };

endmodule