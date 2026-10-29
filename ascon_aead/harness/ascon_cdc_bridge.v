`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ascon_cdc_bridge : safe-domain <-> swept-domain transaction bridge for Ascon.
// Same architecture as convolution/harness/conv_cdc_bridge.v (bundled data +
// request/response toggle synchronizers, one transaction in flight); only the
// payload (651-bit txn, 384-bit result) and the candidate (ascon_cN) changed.
// ---------------------------------------------------------------------------
module ascon_cdc_bridge (
    input  wire         safe_clk,
    input  wire         dut_clk,

    // Active-high resets, synchronous to their respective domains
    input  wire         safe_rst,
    input  wire         dut_rst,

    // Safe-domain transaction input
    input  wire         launch,
    input  wire [650:0] txn_in,

    // Safe-domain transaction output
    output reg  [383:0] result_out,
    output reg          done_pulse
);

    // ============================================================
    // SAFE -> DUT REQUEST SIDE (bundled data written once at launch)
    // ============================================================

    reg [650:0] txn_hold;
    reg         req_toggle;

    reg         busy;
    reg         request_sent;
    reg [1:0]   settle_count;

    (* ASYNC_REG = "TRUE" *)
    reg [2:0]   resp_sync_pipe;
    reg         resp_seen;

    (* ASYNC_REG = "TRUE" *)
    reg [2:0]   req_sync_pipe;
    reg         req_seen;

    (* SHREG_EXTRACT = "NO" *)
    reg [650:0] txn_stage1;

    (* SHREG_EXTRACT = "NO" *)
    reg [650:0] txn_dut;

    reg [383:0] result_hold;
    reg         resp_toggle;

    // ============================================================
    // SAFE-DOMAIN REQUEST / RESPONSE LOGIC
    // ============================================================

    always @(posedge safe_clk) begin

        if (safe_rst) begin

            txn_hold       <= 651'd0;
            req_toggle     <= 1'b0;

            resp_sync_pipe <= 3'b000;
            resp_seen      <= 1'b0;

            result_out     <= 384'd0;
            done_pulse     <= 1'b0;

            busy           <= 1'b0;
            request_sent   <= 1'b0;
            settle_count   <= 2'd0;

        end

        else begin

            if (launch && !busy) begin

                txn_hold     <= txn_in;

                settle_count <= 2'd2;
                request_sent <= 1'b0;
                busy         <= 1'b1;

            end

            else if (busy && !request_sent) begin

                if (settle_count > 2'd1) begin

                    settle_count <= settle_count - 1'b1;

                end

                else begin

                    req_toggle   <= ~req_toggle;
                    settle_count <= 2'd0;
                    request_sent <= 1'b1;

                end
            end

            resp_sync_pipe <= {resp_sync_pipe[1:0], resp_toggle};

            done_pulse <= 1'b0;

            if (resp_sync_pipe[2] != resp_seen) begin

                result_out <= result_hold;
                resp_seen  <= resp_sync_pipe[2];

                done_pulse <= 1'b1;
                busy       <= 1'b0;

            end
        end
    end

    // ============================================================
    // SAFE -> DUT BUNDLED-DATA PIPELINE (plain registers, no reset)
    // ============================================================

    always @(posedge dut_clk) begin
        txn_stage1 <= txn_hold;
        txn_dut    <= txn_stage1;
    end

    // ============================================================
    // DUT-DOMAIN CONTROL
    // ============================================================

    localparam DUT_IDLE = 1'b0;
    localparam DUT_WAIT = 1'b1;

    reg  dut_state;
    reg  seq_go;

    wire         c_start_cipher, c_has_ad, c_has_pt, c_ad_last, c_pt_last;
    wire [127:0] c_key, c_nonce, c_data_in;
    wire [4:0]   c_data_bytes;
    wire         c_cap1;

    wire [127:0] c_ciphertext;
    wire [127:0] c_tag;
    wire         c_cipher_done;

    wire [383:0] cap_res;
    wire         cap_valid;

    always @(posedge dut_clk) begin

        if (dut_rst) begin

            req_sync_pipe <= 3'b000;
            req_seen      <= 1'b0;

            resp_toggle   <= 1'b0;

            dut_state     <= DUT_IDLE;
            seq_go        <= 1'b0;

        end

        else begin

            req_sync_pipe <= {req_sync_pipe[1:0], req_toggle};

            seq_go <= 1'b0;

            case (dut_state)

                DUT_IDLE: begin

                    if (req_sync_pipe[2] != req_seen) begin

                        // Consume this toggle exactly once.
                        req_seen  <= req_sync_pipe[2];
                        seq_go    <= 1'b1;
                        dut_state <= DUT_WAIT;

                    end
                end

                DUT_WAIT: begin

                    if (cap_valid) begin

                        // Hold the completed result stable before
                        // advertising completion across the CDC.
                        resp_toggle <= ~resp_toggle;
                        dut_state   <= DUT_IDLE;

                    end
                end

            endcase
        end
    end

    // result_hold: data bundle, no reset; written exactly when completion is flagged
    always @(posedge dut_clk) begin
        if (dut_state == DUT_WAIT && cap_valid) result_hold <= cap_res;
    end

    // ============================================================
    // TRANSACTION SEQUENCER + RESULT CAPTURE (swept domain)
    // ============================================================

    ascon_txn_seq u_seq (
        .clk          (dut_clk),
        .rst          (dut_rst),
        .go           (seq_go),
        .txn          (txn_dut),

        .start_cipher (c_start_cipher),
        .has_ad       (c_has_ad),
        .has_pt       (c_has_pt),
        .ad_last      (c_ad_last),
        .pt_last      (c_pt_last),
        .key          (c_key),
        .nonce        (c_nonce),
        .data_in      (c_data_in),
        .data_bytes   (c_data_bytes),
        .cap1         (c_cap1)
    );

    ascon_txn_cap u_cap (
        .clk            (dut_clk),
        .rst            (dut_rst),
        .cap1           (c_cap1),
        .cipher_done    (c_cipher_done),
        .ciphertext_out (c_ciphertext),
        .tag_out        (c_tag),
        .res            (cap_res),
        .res_valid      (cap_valid)
    );

    // ============================================================
    // CANDIDATE DUT
    //
    // Only the module token on the next line is changed by the build
    // script (ascon_c0 .. ascon_c4); ports and wiring never change.
    // ============================================================

    ascon_c0 u_candidate (
        .clk            (dut_clk),
        .rst            (dut_rst),
        .start_cipher   (c_start_cipher),
        .has_ad         (c_has_ad),
        .has_pt         (c_has_pt),
        .ad_last        (c_ad_last),
        .pt_last        (c_pt_last),
        .key            (c_key),
        .nonce          (c_nonce),
        .data_in        (c_data_in),
        .data_bytes     (c_data_bytes),
        .ciphertext_out (c_ciphertext),
        .tag_out        (c_tag),
        .cipher_done    (c_cipher_done)
    );

endmodule
