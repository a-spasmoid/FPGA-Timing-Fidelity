`timescale 1ns / 1ps

module tb_runner_rng_continuity;

    reg safe_clk = 1'b0;
    reg safe_rst = 1'b1;

    reg        start_toggle = 1'b0;
    reg [15:0] batch_count  = 16'd0;
    reg [31:0] seed         = 32'h12345678;
    reg [1:0]  workload_mode = 2'd0;   // RANDOM

    wire runner_busy;
    wire done_toggle;
    wire [15:0] tests_run;
    wire [15:0] wrong_count;
    wire [15:0] timeout_count;
    wire [15:0] first_wrong_index;
    wire first_wrong_valid;

    wire timeout_candidate_seen;
    wire timeout_golden_seen;

    wire [71:0] current_pixels;
    wire [71:0] current_kernel;

    wire signed [19:0] candidate_result_dbg;
    wire signed [19:0] expected_result_dbg;

    wire candidate_launch;

    wire signed [19:0] candidate_result;
    wire candidate_done;

    always #10 safe_clk = ~safe_clk;   // 50 MHz

    conv_batch_runner dut (
        .safe_clk               (safe_clk),
        .safe_rst               (safe_rst),

        .start_toggle           (start_toggle),
        .batch_count            (batch_count),
        .seed                   (seed),
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

        .current_pixels         (current_pixels),
        .current_kernel         (current_kernel),
        .candidate_result_dbg   (candidate_result_dbg),
        .expected_result_dbg    (expected_result_dbg),

        .candidate_launch       (candidate_launch),
        .candidate_result       (candidate_result),
        .candidate_done         (candidate_done)
    );

    // For this test only:
    // candidate behaves exactly like the internal golden A0.
    assign candidate_result = dut.golden_result;
    assign candidate_done   = dut.golden_done;

    reg [143:0] seqA [0:9];
    reg [143:0] seqB [0:9];

    integer a_idx;
    integer b_idx;
    integer i;

    task do_reset;
    begin
        safe_rst = 1'b1;
        repeat (5) @(posedge safe_clk);

        safe_rst = 1'b0;

        // Allow start-toggle baseline to arm.
        repeat (3) @(posedge safe_clk);
    end
    endtask

    task start_batch;
        input [15:0] count;
    begin
        batch_count = count;

        @(posedge safe_clk);
        start_toggle = ~start_toggle;

        wait (runner_busy == 1'b1);
        wait (runner_busy == 1'b0);

        @(posedge safe_clk);
    end
    endtask

    initial begin
        a_idx = 0;
        b_idx = 0;

        $display("======================================");
        $display(" PRNG BATCH CONTINUITY TEST");
        $display("======================================");

        // --------------------------------------------------------
        // A: one continuous 10-transaction batch
        // --------------------------------------------------------
        do_reset();

        a_idx = 0;

        fork
            begin
                while (a_idx < 10) begin
                    @(posedge safe_clk);
                    if (candidate_launch) begin
                        seqA[a_idx] = {
                            current_kernel,
                            current_pixels
                        };
                        a_idx = a_idx + 1;
                    end
                end
            end
            begin
                start_batch(16'd10);
            end
        join

        $display("Reference 10-transaction sequence captured.");

        // --------------------------------------------------------
        // B: same seed, but split 4 + 6
        // --------------------------------------------------------
        do_reset();

        b_idx = 0;

        fork
            begin
                while (b_idx < 10) begin
                    @(posedge safe_clk);
                    if (candidate_launch) begin
                        seqB[b_idx] = {
                            current_kernel,
                            current_pixels
                        };
                        b_idx = b_idx + 1;
                    end
                end
            end

            begin
                start_batch(16'd4);
                start_batch(16'd6);
            end
        join

        $display("Split 4+6 sequence captured.");

        // --------------------------------------------------------
        // Compare
        // --------------------------------------------------------
        for (i = 0; i < 10; i = i + 1) begin
            if (seqA[i] !== seqB[i]) begin
                $display(
                    "FAIL at transaction %0d\nA=%h\nB=%h",
                    i, seqA[i], seqB[i]
                );
                $finish;
            end
        end

        $display("");
        $display("PASS:");
        $display("10 transactions == 4 + 6 transactions");
        $display("Batch boundaries do not restart PRNG.");
        $display("Reset + same seed reproduces sequence.");
        $display("");

        $finish;
    end

endmodule