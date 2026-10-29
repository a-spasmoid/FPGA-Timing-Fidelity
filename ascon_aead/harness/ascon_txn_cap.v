`timescale 1ns / 1ps
// ascon_txn_cap : collects {ct1, ct2, tag} from an ascon_core-style output port set.
//
// Every candidate output (cipher_done, ciphertext_out, tag_out) first lands in ONE
// register stage with fanout 1.  This keeps the harness from loading the candidate's
// output pins (cipher_done used to drive the CE of 384 flops directly, which put a
// 7+ ns high-fanout net into the candidate-launched timing paths).
//   ct1 is sampled from the cap1 cycle, ct2 and tag from the cipher_done cycle,
//   both one cycle later than the raw ports.
//   res_valid is a one-cycle pulse with res already stable.
module ascon_txn_cap (
    input  wire         clk,
    input  wire         rst,
    input  wire         cap1,
    input  wire         cipher_done,
    input  wire [127:0] ciphertext_out,
    input  wire [127:0] tag_out,
    output reg  [383:0] res,
    output reg          res_valid
);
    // input stage (fanout 1 on every candidate output)
    reg [127:0] ct_q;
    reg [127:0] tag_q;
    reg         done_q;
    reg         cap1_q;

    always @(posedge clk) begin
        ct_q  <= ciphertext_out;
        tag_q <= tag_out;
        if (rst) begin
            done_q <= 1'b0;
            cap1_q <= 1'b0;
        end
        else begin
            done_q <= cipher_done;
            cap1_q <= cap1;
        end
    end

    reg [127:0] ct1;

    // ct1 / res are data registers: no reset (cuts reset fanout; res_valid gates use).
    always @(posedge clk) begin
        if (cap1_q) ct1 <= ct_q;
        if (done_q) res <= {ct1, ct_q, tag_q};
    end

    always @(posedge clk) begin
        if (rst) res_valid <= 1'b0;
        else     res_valid <= done_q;
    end
endmodule
