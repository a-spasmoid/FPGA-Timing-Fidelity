`timescale 1ns / 1ps

// ============================================================================
// A4 — one-hot moving selector
//
// Difference from A0/A2:
//   A0/A2 keep the operands stationary and use a binary counter to select one
//   of nine byte lanes. A4 still keeps the operands stationary, but replaces
//   the binary counter/decode path with a 9-bit one-hot token. Exactly one bit
//   of select_onehot is high while the accelerator is active. The selected
//   pixel/coefficient bytes are formed by one-hot gating followed by OR
//   reduction, and the token shifts once per MAC cycle.
//
// What stays unchanged:
//   - same 3x3 signed convolution
//   - same precision and result interpretation
//   - one multiply and one accumulation per active cycle
//   - start accepted only while idle
//   - result/done visible on the ninth MAC cycle
//   - initiation interval = 10 cycles
//
// This variant probes CONTROL ENCODING / SELECTION STRUCTURE rather than data
// movement. Unlike A1, the 72-bit operand words never shift after being loaded.
// ============================================================================

module A4(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire [71:0]        pixels,
    input  wire [71:0]        kernel,
    output reg signed [19:0]  result,
    output reg                done
);

    reg [71:0] pixels_reg;
    reg [71:0] kernel_reg;

    // One-hot token: bit 0 corresponds to operand 0, bit 8 to operand 8.
    reg [8:0] select_onehot;

    wire [7:0] pixel_raw;
    wire [7:0] coeff_raw;

    wire signed [8:0]  pixel_signed;
    wire signed [8:0]  coeff_signed;
    wire signed [17:0] product;

    // Explicit one-hot gating.  Synthesis is free to optimize this structure,
    // but the RTL no longer contains a binary 0..8 decoder/select index.
    assign pixel_raw =
          ({8{select_onehot[0]}} & pixels_reg[7:0])
        | ({8{select_onehot[1]}} & pixels_reg[15:8])
        | ({8{select_onehot[2]}} & pixels_reg[23:16])
        | ({8{select_onehot[3]}} & pixels_reg[31:24])
        | ({8{select_onehot[4]}} & pixels_reg[39:32])
        | ({8{select_onehot[5]}} & pixels_reg[47:40])
        | ({8{select_onehot[6]}} & pixels_reg[55:48])
        | ({8{select_onehot[7]}} & pixels_reg[63:56])
        | ({8{select_onehot[8]}} & pixels_reg[71:64]);

    assign coeff_raw =
          ({8{select_onehot[0]}} & kernel_reg[7:0])
        | ({8{select_onehot[1]}} & kernel_reg[15:8])
        | ({8{select_onehot[2]}} & kernel_reg[23:16])
        | ({8{select_onehot[3]}} & kernel_reg[31:24])
        | ({8{select_onehot[4]}} & kernel_reg[39:32])
        | ({8{select_onehot[5]}} & kernel_reg[47:40])
        | ({8{select_onehot[6]}} & kernel_reg[55:48])
        | ({8{select_onehot[7]}} & kernel_reg[63:56])
        | ({8{select_onehot[8]}} & kernel_reg[71:64]);

    assign pixel_signed = {1'b0, pixel_raw};
    assign coeff_signed = {coeff_raw[7], coeff_raw};

    assign product = pixel_signed * coeff_signed;

    reg signed [19:0] accumulator;
    reg               active;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            pixels_reg    <= 72'd0;
            kernel_reg    <= 72'd0;
            select_onehot <= 9'd0;
            accumulator   <= 20'sd0;
            result        <= 20'sd0;
            done          <= 1'b0;
            active        <= 1'b0;
        end

        else begin
            done <= 1'b0;

            if (start && !active) begin
                pixels_reg    <= pixels;
                kernel_reg    <= kernel;
                select_onehot <= 9'b000000001;
                accumulator   <= 20'sd0;
                active        <= 1'b1;
            end

            else if (active) begin
                if (select_onehot[8]) begin
                    result <= accumulator + product;
                    done   <= 1'b1;
                    active <= 1'b0;
                end

                else begin
                    accumulator   <= accumulator + product;
                    select_onehot <= select_onehot << 1;
                end
            end
        end
    end

endmodule
