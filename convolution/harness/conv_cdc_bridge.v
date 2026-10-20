`timescale 1ns / 1ps

module conv_cdc_bridge (
    input  wire         safe_clk,
    input  wire         dut_clk,

    // Active-high resets, synchronous to their respective domains
    input  wire         safe_rst,
    input  wire         dut_rst,

    // Safe-domain transaction input
    input  wire         launch,
    input  wire [71:0]  pixels_in,
    input  wire [71:0]  kernel_in,

    // Safe-domain transaction output
    output reg signed [19:0] result_out,
    output reg               done_pulse
);

    // ============================================================
    // SAFE -> DUT REQUEST SIDE
    //
    // pixels_hold and kernel_hold are bundled data.
    // They are written once at launch and remain unchanged until
    // the corresponding response returns.
    // ============================================================

    reg [71:0] pixels_hold;
    reg [71:0] kernel_hold;

    reg req_toggle;

    // Functional safe-domain transaction state
    reg       busy;
    reg       request_sent;
    reg [1:0] settle_count;

    // ============================================================
    // DUT -> SAFE RESPONSE SYNCHRONIZER
    // ============================================================

    (* ASYNC_REG = "TRUE" *)
    reg [2:0] resp_sync_pipe;

    reg resp_seen;

    // ============================================================
    // DUT-SIDE REQUEST SYNCHRONIZER
    // ============================================================

    (* ASYNC_REG = "TRUE" *)
    reg [2:0] req_sync_pipe;

    reg req_seen;

    // ============================================================
    // SAFE -> DUT BUNDLED-DATA PIPELINE
    //
    // These are deliberately implemented as ordinary registers,
    // rather than independent bit synchronizers.
    //
    // The control toggle crosses through req_sync_pipe while the
    // corresponding wide data bundle is held constant.
    // ============================================================

    (* SHREG_EXTRACT = "NO" *)
    reg [71:0] pixels_stage1;

    (* SHREG_EXTRACT = "NO" *)
    reg [71:0] kernel_stage1;

    (* SHREG_EXTRACT = "NO" *)
    reg [71:0] pixels_dut;

    (* SHREG_EXTRACT = "NO" *)
    reg [71:0] kernel_dut;

    // ============================================================
    // DUT -> SAFE RESPONSE SIDE
    //
    // result_hold remains constant while resp_toggle crosses into
    // the safe domain.
    // ============================================================

    reg signed [19:0] result_hold;
    reg               resp_toggle;

    // ============================================================
    // SAFE-DOMAIN REQUEST / RESPONSE LOGIC
    // ============================================================

    always @(posedge safe_clk) begin

        if (safe_rst) begin

            pixels_hold <= 72'd0;
            kernel_hold <= 72'd0;

            req_toggle <= 1'b0;

            resp_sync_pipe <= 3'b000;
            resp_seen      <= 1'b0;

            result_out <= 20'sd0;
            done_pulse <= 1'b0;

            busy         <= 1'b0;
            request_sent <= 1'b0;
            settle_count <= 2'd0;

        end

        else begin

            // ----------------------------------------------------
            // Capture a new transaction.
            //
            // Only one transaction may be outstanding.
            // ----------------------------------------------------

            if (launch && !busy) begin

                pixels_hold <= pixels_in;
                kernel_hold <= kernel_in;

                // Allow the bundled data to begin propagating toward
                // the DUT before the request toggle is transmitted.
                settle_count <= 2'd2;

                request_sent <= 1'b0;
                busy         <= 1'b1;

            end

            // ----------------------------------------------------
            // After the settling interval, toggle the request bit.
            // ----------------------------------------------------

            else if (busy && !request_sent) begin

                if (settle_count > 2'd1) begin

                    settle_count <= settle_count - 1'b1;

                end

                else begin

                    req_toggle <= ~req_toggle;

                    settle_count <= 2'd0;
                    request_sent <= 1'b1;

                end
            end

            // ----------------------------------------------------
            // Synchronize DUT response toggle into safe_clk.
            // ----------------------------------------------------

            resp_sync_pipe <= {
                resp_sync_pipe[1:0],
                resp_toggle
            };

            // done_pulse is asserted for exactly one safe cycle.
            done_pulse <= 1'b0;

            // ----------------------------------------------------
            // A changed synchronized response toggle means the DUT
            // has completed the current transaction.
            //
            // result_hold has already been stable while the toggle
            // propagated through the synchronizer.
            // ----------------------------------------------------

            if (resp_sync_pipe[2] != resp_seen) begin

                result_out <= result_hold;

                resp_seen <= resp_sync_pipe[2];

                done_pulse <= 1'b1;
                busy       <= 1'b0;

            end
        end
    end

    // ============================================================
    // SAFE -> DUT BUNDLED-DATA PIPELINE
    //
    // No reset is required here. These registers are not consumed
    // until a synchronized request arrives, by which time valid
    // transaction data has propagated through them.
    // ============================================================

    always @(posedge dut_clk) begin

        pixels_stage1 <= pixels_hold;
        kernel_stage1 <= kernel_hold;

        pixels_dut <= pixels_stage1;
        kernel_dut <= kernel_stage1;

    end

    // ============================================================
    // DUT-DOMAIN CONTROL
    // ============================================================

    localparam DUT_IDLE  = 2'd0;
    localparam DUT_START = 2'd1;
    localparam DUT_WAIT  = 2'd2;

    reg [1:0] dut_state;

    reg conv_start_reg;

    wire signed [19:0] conv_result;
    wire               conv_done;

    always @(posedge dut_clk) begin

        if (dut_rst) begin

            req_sync_pipe <= 3'b000;
            req_seen      <= 1'b0;

            result_hold <= 20'sd0;
            resp_toggle <= 1'b0;

            dut_state      <= DUT_IDLE;
            conv_start_reg <= 1'b0;

        end

        else begin

            // ----------------------------------------------------
            // Synchronize safe-domain request toggle into dut_clk.
            // ----------------------------------------------------

            req_sync_pipe <= {
                req_sync_pipe[1:0],
                req_toggle
            };

            // Default low; explicitly asserted for one DUT cycle
            // when a new request is accepted.
            conv_start_reg <= 1'b0;

            case (dut_state)

                // =================================================
                // WAIT FOR NEW REQUEST
                // =================================================

                DUT_IDLE: begin

                    if (req_sync_pipe[2] != req_seen) begin

                        // Consume this toggle exactly once.
                        req_seen <= req_sync_pipe[2];

                        // Begin the candidate transaction.
                        conv_start_reg <= 1'b1;

                        dut_state <= DUT_START;

                    end
                end

                // =================================================
                // START PULSE COMPLETION
                //
                // conv_start_reg was asserted after the previous
                // edge. A0 therefore observes it at this edge.
                // =================================================

                DUT_START: begin

                    dut_state <= DUT_WAIT;

                end

                // =================================================
                // WAIT FOR CANDIDATE COMPLETION
                // =================================================

                DUT_WAIT: begin

                    if (conv_done) begin

                        // Hold the completed result stable before
                        // advertising completion across the CDC.
                        result_hold <= conv_result;

                        resp_toggle <= ~resp_toggle;

                        dut_state <= DUT_IDLE;

                    end
                end

                default: begin

                    dut_state <= DUT_IDLE;

                end

            endcase
        end
    end

    // ============================================================
    // CANDIDATE DUT
    //
    // For this build the candidate is A0. Later candidate builds
    // can replace this instantiated RTL while leaving the complete
    // measurement infrastructure unchanged.
    // ============================================================

    A6 u_candidate (
        .clk    (dut_clk),
        .rst    (~dut_rst),
        .start  (conv_start_reg),
        .pixels (pixels_dut),
        .kernel (kernel_dut),
        .result (conv_result),
        .done   (conv_done)
    );

endmodule