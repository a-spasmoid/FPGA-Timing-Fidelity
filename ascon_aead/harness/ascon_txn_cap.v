`timescale 1ns / 1ps
// ascon_txn_cap : collects {ct1, ct2, tag} from an ascon_core-style output port set.
//   ct1 is sampled while cap1 is high; ct2 and tag are sampled in the cipher_done cycle.
//   res_valid is a one-cycle pulse, the cycle after cipher_done, with res already stable.
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
    reg [127:0] ct1;

    always @(posedge clk) begin
        if (rst) begin
            ct1       <= 128'd0;
            res       <= 384'd0;
            res_valid <= 1'b0;
        end
        else begin
            res_valid <= 1'b0;
            if (cap1) ct1 <= ciphertext_out;
            if (cipher_done) begin
                res       <= {ct1, ciphertext_out, tag_out};
                res_valid <= 1'b1;
            end
        end
    end
endmodule
