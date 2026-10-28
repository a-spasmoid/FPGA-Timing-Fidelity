`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ascon_batch_runner : safe-domain batch controller / golden checker.
// Same protocol, status counters and timeout behaviour as conv_batch_runner.v.
// Payload: 651-bit Ascon transaction in, 384-bit {ct1, ct2, tag} result compared.
// Golden reference = ascon_c0 (the unmodified baseline) in the SAFE clock domain.
//
// Workload (frozen, mirrored by py/ascon_workload.py):
//   MODE_RANDOM   xorshift128 stream seeded once after reset from `seed`,
//                 21 words / transaction, continues across batches
//   MODE_DIRECTED DIRECTED_N fixed vectors (rtl/ascon_directed.vh), index restarts
//                 at every batch start -> use batch_count = multiple of 8
// ---------------------------------------------------------------------------
module ascon_batch_runner #(
    parameter integer TIMEOUT_CYCLES = 4096
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
    output reg [650:0]  current_txn,
    output reg [383:0]  candidate_result_dbg,
    output reg [383:0]  expected_result_dbg,

    // Candidate interface
    output reg          candidate_launch,
    input  wire [383:0] candidate_result,
    input  wire         candidate_done
);

    localparam MODE_RANDOM   = 2'd0;
    localparam MODE_DIRECTED = 2'd1;

    localparam integer DIRECTED_N = 8;
    localparam integer WORDS      = 21;

    localparam ST_IDLE    = 3'd0;
    localparam ST_PREPARE = 3'd1;
    localparam ST_LAUNCH  = 3'd2;
    localparam ST_WAIT    = 3'd3;

    reg [2:0] state;

    reg start_seen;
    reg start_armed;

    `include "ascon_directed.vh"

    // ============================================================
    // GOLDEN ascon_c0 - SAFE CLOCK DOMAIN
    // ============================================================

    reg          golden_go;
    wire         g_start_cipher, g_has_ad, g_has_pt, g_ad_last, g_pt_last;
    wire [127:0] g_key, g_nonce, g_data_in;
    wire [4:0]   g_data_bytes;
    wire         g_cap1;
    wire [127:0] g_ciphertext, g_tag;
    wire         g_cipher_done;

    wire [383:0] golden_result;
    wire         golden_done;

    ascon_txn_seq u_golden_seq (
        .clk          (safe_clk),
        .rst          (safe_rst),
        .go           (golden_go),
        .txn          (current_txn),

        .start_cipher (g_start_cipher),
        .has_ad       (g_has_ad),
        .has_pt       (g_has_pt),
        .ad_last      (g_ad_last),
        .pt_last      (g_pt_last),
        .key          (g_key),
        .nonce        (g_nonce),
        .data_in      (g_data_in),
        .data_bytes   (g_data_bytes),
        .cap1         (g_cap1)
    );

    ascon_txn_cap u_golden_cap (
        .clk            (safe_clk),
        .rst            (safe_rst),
        .cap1           (g_cap1),
        .cipher_done    (g_cipher_done),
        .ciphertext_out (g_ciphertext),
        .tag_out        (g_tag),
        .res            (golden_result),
        .res_valid      (golden_done)
    );

    ascon_c0 u_golden (
        .clk            (safe_clk),
        .rst            (safe_rst),
        .start_cipher   (g_start_cipher),
        .has_ad         (g_has_ad),
        .has_pt         (g_has_pt),
        .ad_last        (g_ad_last),
        .pt_last        (g_pt_last),
        .key            (g_key),
        .nonce          (g_nonce),
        .data_in        (g_data_in),
        .data_bytes     (g_data_bytes),
        .ciphertext_out (g_ciphertext),
        .tag_out        (g_tag),
        .cipher_done    (g_cipher_done)
    );

    // ============================================================
    // RESULT HOLDING
    // ============================================================

    reg candidate_seen;
    reg golden_seen;

    reg [383:0] candidate_saved;
    reg [383:0] golden_saved;

    reg [15:0]  timeout_ctr;
    reg [2:0]   directed_index;
    reg [4:0]   prep_cnt;

    // ============================================================
    // DETERMINISTIC PRNG : xorshift128 (x, y, z, w)
    //
    //   t = x ^ (x << 11);  x = y; y = z; z = w;
    //   w = w ^ (w >> 19) ^ t ^ (t >> 8);   output = new w
    // ============================================================

    reg rng_initialized;
    reg [31:0] rx, ry, rz, rw;

    wire [31:0] rt      = rx ^ (rx << 11);
    wire [31:0] w_next  = rw ^ (rw >> 19) ^ rt ^ (rt >> 8);

    wire [31:0] sx = seed ^ 32'h243F6A88;
    wire [31:0] sy = seed ^ 32'h85A308D3;
    wire [31:0] sz = seed ^ 32'h13198A2E;
    wire [31:0] sw = seed ^ 32'h03707344;

    // 21 words gathered oldest-first; the last one is w_next of the final PREPARE cycle
    reg  [671:0] pool;
    wire [671:0] pool_fin = {pool[639:0], w_next};

    wire [31:0] meta_w = pool_fin[31:0];
    wire        r_has_ad  = (meta_w[1:0] != 2'b00);
    wire [4:0]  r_ad_b    = (meta_w[7:4] == 4'd0) ? 5'd1 : {1'b0, meta_w[7:4]};
    wire [4:0]  r_pt2_b   = {1'b0, meta_w[15:12]};

    wire [650:0] random_txn = {
        pool_fin[671:32],       // key, nonce, ad, pt1, pt2  (w0..w19)
        r_has_ad, r_ad_b, r_pt2_b
    };

    // ============================================================
    // RESULT AVAILABILITY
    // ============================================================

    wire [383:0] candidate_value_now = candidate_done ? candidate_result : candidate_saved;
    wire [383:0] golden_value_now    = golden_done    ? golden_result    : golden_saved;

    wire both_results_available =
        (candidate_seen || candidate_done) &&
        (golden_seen    || golden_done);

    // ============================================================
    // MAIN RUNNER FSM
    // ============================================================

    always @(posedge safe_clk) begin

        if (safe_rst) begin

            state <= ST_IDLE;

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

            current_txn          <= 651'd0;
            candidate_result_dbg <= 384'd0;
            expected_result_dbg  <= 384'd0;

            candidate_launch <= 1'b0;
            golden_go        <= 1'b0;

            candidate_seen  <= 1'b0;
            golden_seen     <= 1'b0;

            candidate_saved <= 384'd0;
            golden_saved    <= 384'd0;

            timeout_ctr    <= 16'd0;
            directed_index <= 3'd0;
            prep_cnt       <= 5'd0;

            rng_initialized <= 1'b0;
            pool            <= 672'd0;

            rx <= 32'h00000001;
            ry <= 32'h00000002;
            rz <= 32'h00000003;
            rw <= 32'h00000004;
        end

        else begin

            candidate_launch <= 1'b0;
            golden_go        <= 1'b0;

            // Absorb whatever start_toggle level exists after reset.
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

                            // Seed the PRNG only on the first batch after reset;
                            // later batches continue the same stream.
                            if (!rng_initialized) begin
                                rx <= sx;
                                ry <= sy;
                                rz <= sz;
                                rw <= sw;

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
                                prep_cnt    <= 5'd0;
                                state       <= ST_PREPARE;

                            end
                        end
                    end

                    // ====================================================
                    // PREPARE NEXT TRANSACTION
                    //   directed : 1 cycle
                    //   random   : 21 cycles (one PRNG word per cycle)
                    // ====================================================
                    ST_PREPARE: begin

                        candidate_seen <= 1'b0;
                        golden_seen    <= 1'b0;

                        timeout_ctr <= 16'd0;

                        if (workload_mode == MODE_DIRECTED) begin

                            current_txn <= directed_txn(directed_index);

                            if (directed_index == (DIRECTED_N - 1))
                                directed_index <= 3'd0;
                            else
                                directed_index <= directed_index + 1'b1;

                            state <= ST_LAUNCH;

                        end

                        else begin

                            rx <= ry;
                            ry <= rz;
                            rz <= rw;
                            rw <= w_next;

                            pool <= pool_fin;

                            if (prep_cnt == (WORDS - 1)) begin

                                current_txn <= random_txn;
                                prep_cnt    <= 5'd0;
                                state       <= ST_LAUNCH;

                            end

                            else begin

                                prep_cnt <= prep_cnt + 1'b1;

                            end
                        end
                    end

                    // ====================================================
                    // LAUNCH : golden and candidate start from the same
                    // prepared transaction on the same safe-domain cycle.
                    // ====================================================
                    ST_LAUNCH: begin

                        candidate_launch <= 1'b1;
                        golden_go        <= 1'b1;

                        state <= ST_WAIT;

                    end

                    // ====================================================
                    // WAIT / COMPARE / TIMEOUT
                    // ====================================================
                    ST_WAIT: begin

                        if (golden_done) begin

                            golden_saved <= golden_result;
                            golden_seen  <= 1'b1;

                            expected_result_dbg <= golden_result;

                        end

                        if (candidate_done) begin

                            candidate_saved <= candidate_result;
                            candidate_seen  <= 1'b1;

                            candidate_result_dbg <= candidate_result;

                        end

                        if (both_results_available) begin

                            tests_run <= tests_run + 1'b1;

                            candidate_result_dbg <= candidate_value_now;
                            expected_result_dbg  <= golden_value_now;

                            if (candidate_value_now != golden_value_now) begin

                                wrong_count <= wrong_count + 1'b1;

                                if (!first_wrong_valid) begin

                                    first_wrong_index <= tests_run;
                                    first_wrong_valid <= 1'b1;

                                end
                            end

                            if (tests_run == (batch_count - 1'b1)) begin

                                runner_busy <= 1'b0;
                                done_toggle <= ~done_toggle;
                                state       <= ST_IDLE;

                            end

                            else begin

                                prep_cnt <= 5'd0;
                                state    <= ST_PREPARE;

                            end
                        end

                        else if (timeout_ctr == TIMEOUT_CYCLES - 1) begin

                            timeout_count <= timeout_count + 1'b1;

                            timeout_candidate_seen <= candidate_seen || candidate_done;
                            timeout_golden_seen    <= golden_seen    || golden_done;

                            runner_busy <= 1'b0;
                            done_toggle <= ~done_toggle;
                            state       <= ST_IDLE;

                        end

                        else begin

                            timeout_ctr <= timeout_ctr + 1'b1;

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
