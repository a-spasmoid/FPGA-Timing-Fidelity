`timescale 1ns / 1ps

module conv_batch_runner #(
    parameter integer TIMEOUT_CYCLES = 1024
)(
    input  wire         safe_clk,
    input  wire         safe_rst,

    // Batch control
    input  wire         start_toggle,
    input  wire [15:0]  batch_count,
    input  wire [31:0]  seed,
    input  wire [1:0]   workload_mode,

    // Batch status/results
    output reg          runner_busy,
    output reg          done_toggle,
    output reg [15:0]   tests_run,
    output reg [15:0]   wrong_count,
    output reg [15:0]   timeout_count,
    output reg [15:0]   first_wrong_index,
    output reg          first_wrong_valid,

    // Timeout classification
    output reg          timeout_candidate_seen,
    output reg          timeout_golden_seen,

    // Current transaction / result visibility
    output reg [71:0]   current_pixels,
    output reg [71:0]   current_kernel,
    output reg signed [19:0] candidate_result_dbg,
    output reg signed [19:0] expected_result_dbg,

    // Candidate interface
    output reg          candidate_launch,
    input  wire signed [19:0] candidate_result,
    input  wire               candidate_done
);

    localparam MODE_RANDOM   = 2'd0;
    localparam MODE_DIRECTED = 2'd1;

    localparam ST_IDLE    = 3'd0;
    localparam ST_PREPARE = 3'd1;
    localparam ST_LAUNCH  = 3'd2;
    localparam ST_WAIT    = 3'd3;

    reg [2:0] state;

    // Toggle-command tracking
    reg start_seen;
    reg start_armed;

    // ============================================================
    // GOLDEN A0 - SAFE CLOCK DOMAIN
    // ============================================================

    reg  golden_start;
    wire signed [19:0] golden_result;
    wire               golden_done;

    A0 u_golden (
        .clk    (safe_clk),
        .rst    (~safe_rst),
        .start  (golden_start),
        .pixels (current_pixels),
        .kernel (current_kernel),
        .result (golden_result),
        .done   (golden_done)
    );

    // ============================================================
    // RESULT HOLDING
    // ============================================================

    reg candidate_seen;
    reg golden_seen;

    reg signed [19:0] candidate_saved;
    reg signed [19:0] golden_saved;

    reg [15:0] timeout_ctr;
    reg [2:0]  directed_index;

    // ============================================================
    // DETERMINISTIC PRNG
    // ============================================================

    reg rng_initialized;

    reg [31:0] rng0;
    reg [31:0] rng1;
    reg [31:0] rng2;
    reg [31:0] rng3;
    reg [31:0] rng4;

    // ------------------------------------------------------------
    // xorshift32 next-state logic
    //
    // Equivalent to:
    //
    // y = x;
    // y = y ^ (y << 13);
    // y = y ^ (y >> 17);
    // y = y ^ (y << 5);
    // ------------------------------------------------------------

    wire [31:0] rng0_x1;
    wire [31:0] rng0_x2;
    wire [31:0] rng0_next;

    assign rng0_x1   = rng0 ^ (rng0 << 13);
    assign rng0_x2   = rng0_x1 ^ (rng0_x1 >> 17);
    assign rng0_next = rng0_x2 ^ (rng0_x2 << 5);

    wire [31:0] rng1_x1;
    wire [31:0] rng1_x2;
    wire [31:0] rng1_next;

    assign rng1_x1   = rng1 ^ (rng1 << 13);
    assign rng1_x2   = rng1_x1 ^ (rng1_x1 >> 17);
    assign rng1_next = rng1_x2 ^ (rng1_x2 << 5);

    wire [31:0] rng2_x1;
    wire [31:0] rng2_x2;
    wire [31:0] rng2_next;

    assign rng2_x1   = rng2 ^ (rng2 << 13);
    assign rng2_x2   = rng2_x1 ^ (rng2_x1 >> 17);
    assign rng2_next = rng2_x2 ^ (rng2_x2 << 5);

    wire [31:0] rng3_x1;
    wire [31:0] rng3_x2;
    wire [31:0] rng3_next;

    assign rng3_x1   = rng3 ^ (rng3 << 13);
    assign rng3_x2   = rng3_x1 ^ (rng3_x1 >> 17);
    assign rng3_next = rng3_x2 ^ (rng3_x2 << 5);

    wire [31:0] rng4_x1;
    wire [31:0] rng4_x2;
    wire [31:0] rng4_next;

    assign rng4_x1   = rng4 ^ (rng4 << 13);
    assign rng4_x2   = rng4_x1 ^ (rng4_x1 >> 17);
    assign rng4_next = rng4_x2 ^ (rng4_x2 << 5);

    // ------------------------------------------------------------
    // Initial PRNG states derived deterministically from software
    // seed.
    //
    // xorshift32 must never enter the all-zero state, so replace
    // a zero mixed seed with 1.
    // ------------------------------------------------------------

    wire [31:0] seed0_mix;
    wire [31:0] seed1_mix;
    wire [31:0] seed2_mix;
    wire [31:0] seed3_mix;
    wire [31:0] seed4_mix;

    assign seed0_mix = seed ^ 32'h243F6A88;
    assign seed1_mix = seed ^ 32'h85A308D3;
    assign seed2_mix = seed ^ 32'h13198A2E;
    assign seed3_mix = seed ^ 32'h03707344;
    assign seed4_mix = seed ^ 32'hA4093822;

    wire [31:0] seed0_init;
    wire [31:0] seed1_init;
    wire [31:0] seed2_init;
    wire [31:0] seed3_init;
    wire [31:0] seed4_init;

    assign seed0_init =
        (seed0_mix == 32'd0) ? 32'h00000001 : seed0_mix;

    assign seed1_init =
        (seed1_mix == 32'd0) ? 32'h00000001 : seed1_mix;

    assign seed2_init =
        (seed2_mix == 32'd0) ? 32'h00000001 : seed2_mix;

    assign seed3_init =
        (seed3_mix == 32'd0) ? 32'h00000001 : seed3_mix;

    assign seed4_init =
        (seed4_mix == 32'd0) ? 32'h00000001 : seed4_mix;

    // Exactly the same 144 random bits consumed by the previous
    // runner's random_pool[143:0].
    wire [143:0] random_pool;

    assign random_pool = {
        rng4_next[15:0],
        rng3_next,
        rng2_next,
        rng1_next,
        rng0_next
    };

    // ============================================================
    // RESULT AVAILABILITY
    // ============================================================

    // If a done pulse arrives this cycle, use the live result.
    // Otherwise use the previously saved result.
    wire signed [19:0] candidate_value_now;
    wire signed [19:0] golden_value_now;

    assign candidate_value_now =
        candidate_done ? candidate_result : candidate_saved;

    assign golden_value_now =
        golden_done ? golden_result : golden_saved;

    wire both_results_available;

    assign both_results_available =
        (candidate_seen || candidate_done) &&
        (golden_seen    || golden_done);

    // ============================================================
    // MAIN RUNNER FSM
    // ============================================================

    always @(posedge safe_clk) begin

        if (safe_rst) begin

            state <= ST_IDLE;

            // Reset to constants.
            // The first safe-clock edge after reset absorbs the
            // existing start_toggle value as the command baseline.
            start_seen  <= 1'b0;
            start_armed <= 1'b0;

            runner_busy <= 1'b0;
            done_toggle <= 1'b0;

            tests_run     <= 16'd0;
            wrong_count   <= 16'd0;
            timeout_count <= 16'd0;

            first_wrong_index <= 16'd0;
            first_wrong_valid <= 1'b0;

            timeout_candidate_seen <= 1'b0;
            timeout_golden_seen    <= 1'b0;

            current_pixels <= 72'd0;
            current_kernel <= 72'd0;

            candidate_result_dbg <= 20'sd0;
            expected_result_dbg  <= 20'sd0;

            candidate_launch <= 1'b0;
            golden_start     <= 1'b0;

            candidate_seen  <= 1'b0;
            golden_seen     <= 1'b0;

            candidate_saved <= 20'sd0;
            golden_saved    <= 20'sd0;

            timeout_ctr    <= 16'd0;
            directed_index <= 3'd0;

            rng_initialized <= 1'b0;

            rng0 <= 32'h00000001;
            rng1 <= 32'h00000002;
            rng2 <= 32'h00000003;
            rng3 <= 32'h00000004;
            rng4 <= 32'h00000005;
        end

        else begin

            // One-cycle pulses unless explicitly asserted below.
            candidate_launch <= 1'b0;
            golden_start     <= 1'b0;

            // ----------------------------------------------------
            // ARM START-TOGGLE DETECTOR
            //
            // Absorb whatever start_toggle level exists immediately
            // after reset so an old software control value is not
            // mistaken for a new batch request.
            // ----------------------------------------------------

            if (!start_armed) begin

                start_seen  <= start_toggle;
                start_armed <= 1'b1;

            end

            else begin

                case (state)

                    // ====================================================
                    // IDLE
                    // ====================================================

                    ST_IDLE: begin

                        runner_busy <= 1'b0;

                        if (start_toggle != start_seen) begin

                            start_seen <= start_toggle;

                            tests_run     <= 16'd0;
                            wrong_count   <= 16'd0;
                            timeout_count <= 16'd0;

                            first_wrong_index <= 16'd0;
                            first_wrong_valid <= 1'b0;

                            timeout_candidate_seen <= 1'b0;
                            timeout_golden_seen    <= 1'b0;

                            directed_index <= 3'd0;

                            // Initialize deterministic PRNG streams
                            // from the software-provided seed.
                            if (!rng_initialized) begin
                                rng0 <= seed0_init;
                                rng1 <= seed1_init;
                                rng2 <= seed2_init;
                                rng3 <= seed3_init;
                                rng4 <= seed4_init;
                            
                                rng_initialized <= 1'b1;
                            end 

                            candidate_seen <= 1'b0;
                            golden_seen    <= 1'b0;

                            timeout_ctr <= 16'd0;

                            if (batch_count == 16'd0) begin

                                done_toggle <= ~done_toggle;

                            end

                            else begin

                                runner_busy <= 1'b1;
                                state       <= ST_PREPARE;

                            end
                        end
                    end

                    // ====================================================
                    // PREPARE NEXT TRANSACTION
                    // ====================================================

                    ST_PREPARE: begin

                        candidate_seen <= 1'b0;
                        golden_seen    <= 1'b0;

                        timeout_ctr <= 16'd0;

                        if (workload_mode == MODE_DIRECTED) begin

                            case (directed_index)

                                3'd0: begin

                                    current_pixels <=
                                        72'h0102040810204080FF;

                                    current_kernel <=
                                        72'h000000000000000001;

                                end

                                3'd1: begin

                                    current_pixels <=
                                        72'h0102040810204080FF;

                                    current_kernel <=
                                        72'h010000000000000000;

                                end

                                3'd2: begin

                                    current_pixels <=
                                        72'h010203040506070809;

                                    current_kernel <=
                                        72'h09FE07FC05FA03F801;

                                end

                                3'd3: begin

                                    current_pixels <=
                                        72'hFFFFFFFFFFFFFFFFFF;

                                    current_kernel <=
                                        72'h7F7F7F7F7F7F7F7F7F;

                                end

                                3'd4: begin

                                    current_pixels <=
                                        72'hFFFFFFFFFFFFFFFFFF;

                                    current_kernel <=
                                        72'h808080808080808080;

                                end

                                default: begin

                                    current_pixels <=
                                        72'h00FF01FE02FD03FC04;

                                    current_kernel <=
                                        72'h807FFF0102FE40C000;

                                end

                            endcase

                            if (directed_index == 3'd5)
                                directed_index <= 3'd0;
                            else
                                directed_index <=
                                    directed_index + 1'b1;

                        end

                        else begin

                            current_pixels <= random_pool[71:0];
                            current_kernel <= random_pool[143:72];

                            rng0 <= rng0_next;
                            rng1 <= rng1_next;
                            rng2 <= rng2_next;
                            rng3 <= rng3_next;
                            rng4 <= rng4_next;

                        end

                        state <= ST_LAUNCH;
                    end

                    // ====================================================
                    // LAUNCH
                    //
                    // Golden and candidate start from the same prepared
                    // transaction on the same safe-domain cycle.
                    // ====================================================

                    ST_LAUNCH: begin

                        candidate_launch <= 1'b1;
                        golden_start     <= 1'b1;

                        state <= ST_WAIT;

                    end

                    // ====================================================
                    // WAIT / COMPARE / TIMEOUT
                    // ====================================================

                    ST_WAIT: begin

                        // Golden may finish first.
                        if (golden_done) begin

                            golden_saved <= golden_result;
                            golden_seen  <= 1'b1;

                            expected_result_dbg <= golden_result;

                        end

                        // Candidate may finish first.
                        if (candidate_done) begin

                            candidate_saved <= candidate_result;
                            candidate_seen  <= 1'b1;

                            candidate_result_dbg <= candidate_result;

                        end

                        // ------------------------------------------------
                        // Both results available
                        // ------------------------------------------------

                        if (both_results_available) begin

                            tests_run <= tests_run + 1'b1;

                            candidate_result_dbg <=
                                candidate_value_now;

                            expected_result_dbg <=
                                golden_value_now;

                            if (
                                candidate_value_now !=
                                golden_value_now
                            ) begin

                                wrong_count <=
                                    wrong_count + 1'b1;

                                if (!first_wrong_valid) begin

                                    first_wrong_index <= tests_run;
                                    first_wrong_valid <= 1'b1;

                                end
                            end

                            if (
                                tests_run ==
                                (batch_count - 1'b1)
                            ) begin

                                runner_busy <= 1'b0;
                                done_toggle <= ~done_toggle;
                                state       <= ST_IDLE;

                            end

                            else begin

                                state <= ST_PREPARE;

                            end
                        end

                        // ------------------------------------------------
                        // Transaction timeout
                        // ------------------------------------------------

                        else if (
                            timeout_ctr ==
                            TIMEOUT_CYCLES - 1
                        ) begin

                            timeout_count <=
                                timeout_count + 1'b1;

                            // Record which side had completed at the
                            // timeout point.
                            timeout_candidate_seen <=
                                candidate_seen ||
                                candidate_done;

                            timeout_golden_seen <=
                                golden_seen ||
                                golden_done;

                            runner_busy <= 1'b0;
                            done_toggle <= ~done_toggle;
                            state       <= ST_IDLE;

                        end

                        else begin

                            timeout_ctr <=
                                timeout_ctr + 1'b1;

                        end
                    end

                    default: begin

                        state <= ST_IDLE;

                    end

                endcase
            end
        end
    end

endmodule