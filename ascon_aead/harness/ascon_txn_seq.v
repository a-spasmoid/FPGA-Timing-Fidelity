`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ascon_txn_seq : drives one fixed-shape Ascon-AEAD128 transaction into an
// ascon_core-style port list, using only a cycle count since `start_cipher`.
//
// Used identically in the safe domain (golden) and the swept domain (candidate),
// so both see the same input waveform. Every candidate is cycle-equivalent
// (tb/ascon_equivalence_tb.sv), which makes a fixed schedule valid:
//
//   t = 0 : start_cipher visible at the core pins (controller in IDLE)
//   block load cycle (core samples data_in at the end of this cycle):
//     has_ad=1 : AD at t=15, PT1 at t=25, PT2 at t=35, cipher_done at t=49
//     has_ad=0 :             PT1 at t=15, PT2 at t=25, cipher_done at t=39
//   ciphertext_out shows PT1's ciphertext during cycle PT1+1  -> cap1 strobe
//
// All outputs are registers so the candidate's inputs come straight from flops.
// txn = {key, nonce, ad, pt1, pt2, has_ad, ad_bytes[4:0], pt2_bytes[4:0]}
// ---------------------------------------------------------------------------
module ascon_txn_seq #(
    parameter integer L0   = 15,   // load cycle of the first absorbed block
    parameter integer STEP = 10    // cycles between consecutive block loads (P8 + load)
)(
    input  wire         clk,
    input  wire         rst,        // synchronous, active high
    input  wire         go,         // one-cycle pulse: begin a transaction
    input  wire [650:0] txn,        // must be stable from `go` until cipher_done

    output reg          start_cipher,
    output reg          has_ad,
    output wire         has_pt,
    output reg          ad_last,
    output reg          pt_last,
    output reg  [127:0] key,
    output reg  [127:0] nonce,
    output reg  [127:0] data_in,
    output reg  [4:0]   data_bytes,

    output reg          cap1        // high during the cycle ciphertext_out holds PT block 1
);

    assign has_pt = 1'b1;

    wire [127:0] t_key  = txn[650:523];
    wire [127:0] t_non  = txn[522:395];
    wire [127:0] t_ad   = txn[394:267];
    wire [127:0] t_pt1  = txn[266:139];
    wire [127:0] t_pt2  = txn[138:11];
    wire         t_hasad = txn[10];
    wire [4:0]   t_adb  = txn[9:5];
    wire [4:0]   t_pt2b = txn[4:0];

    reg        running;
    reg [6:0]  cnt;                 // t of the current cycle (saturates)
    wire [6:0] n       = cnt + 7'd1; // t of the next cycle
    wire [6:0] pt1_t   = L0[6:0] + (has_ad ? STEP[6:0] : 7'd0);

    // Block-select decision for load cycle k, registered one cycle ahead so the
    // 128-bit data_in mux is driven straight from flops (it used to be driven from a
    // counter-compare cone: 4 LUT levels + fanout 130 = the slowest wrapper path).
    //   sel_ad : load the AD block      sel_p1 : load PT block 1     else PT block 2
    function f_selad(input h, input [7:0] k);
        f_selad = h && (k <= L0);
    endfunction
    function f_selp1(input h, input [7:0] k);
        f_selp1 = !f_selad(h, k) && (k <= (L0 + (h ? STEP : 0)));
    endfunction

    (* MAX_FANOUT = 40 *) reg sel_ad;   // valid for k = cnt + 1
    (* MAX_FANOUT = 40 *) reg sel_p1;
    wire [7:0] k_next = {1'b0, cnt} + 8'd2;   // k for the following cycle

    // Control registers (reset).  The 400+ data-path flops below are deliberately
    // NOT reset: reset fanout of ~2000 pins was the slowest wrapper path.
    always @(posedge clk) begin
        if (rst) begin
            start_cipher <= 1'b0;
            has_ad       <= 1'b0;
            ad_last      <= 1'b1;
            pt_last      <= 1'b0;
            cap1         <= 1'b0;
            running      <= 1'b0;
            cnt          <= 7'd0;
            sel_ad       <= 1'b0;
            sel_p1       <= 1'b0;
        end
        else if (go) begin
            has_ad       <= t_hasad;
            ad_last      <= 1'b1;
            pt_last      <= 1'b0;
            start_cipher <= 1'b1;
            cap1         <= 1'b0;
            running      <= 1'b1;
            cnt          <= 7'd0;
            sel_ad       <= f_selad(t_hasad, 8'd1);
            sel_p1       <= f_selp1(t_hasad, 8'd1);
        end
        else if (running) begin
            start_cipher <= 1'b0;
            if (cnt != 7'd127) cnt <= n;
            sel_ad       <= f_selad(has_ad, k_next);
            sel_p1       <= f_selp1(has_ad, k_next);
            pt_last <= (n > pt1_t);
            cap1    <= (cnt == pt1_t);
        end
    end

    // Data path (no reset; only consumed after `go`).
    always @(posedge clk) begin
        if (go) begin
            key        <= t_key;
            nonce      <= t_non;
            data_in    <= t_hasad ? t_ad  : t_pt1;
            data_bytes <= t_hasad ? t_adb : 5'd0;
        end
        else if (running) begin
            if (sel_ad) begin
                data_in    <= t_ad;
                data_bytes <= t_adb;
            end
            else if (sel_p1) begin
                data_in    <= t_pt1;
                data_bytes <= 5'd0;
            end
            else begin
                data_in    <= t_pt2;
                data_bytes <= t_pt2b;
            end
        end
    end

endmodule
