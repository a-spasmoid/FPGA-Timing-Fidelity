`timescale 1ns / 1ps

// ============================================================================
// A5 — registered-product / split-MAC datapath
//
// Difference from A0/A2:
//   A0/A2 place operand selection, sign/zero extension, multiplication and the
//   accumulator addition in the same register-to-register computation path.
//   A5 inserts a register between the multiplier and accumulator.  The first
//   product is captured on the accepted-start edge (E0); during E1..E8 the
//   previously registered product is accumulated while the next product is
//   selected and registered.  E9 accumulates the ninth registered product and
//   asserts done.
//
// This preserves the EXTERNAL transaction contract:
//   - start accepted at E0 only while idle
//   - done/result on E9
//   - earliest next accepted start at E10
//   - one multiplier, one accumulator stream, same arithmetic precision
//
// Internally, however, the long combinational MAC path is split into:
//     selector -> multiplier -> product_reg
//     product_reg -> accumulator adder -> accumulator/result reg
//
// This variant probes REGISTER PLACEMENT / RETIMING rather than selector syntax.
// ============================================================================

module A5(
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

    // Index of the product that should be captured NEXT.
    // 1..8 select operands 1..8; 9 means product_reg already holds product 8
    // and the current cycle is the final accumulation cycle.
    reg [3:0] next_index;

    // Product 0 is generated directly from the input bundle on E0.
    wire signed [8:0] start_pixel_signed;
    wire signed [8:0] start_coeff_signed;
    wire signed [17:0] start_product;

    assign start_pixel_signed = {1'b0, pixels[7:0]};
    assign start_coeff_signed = {kernel[7], kernel[7:0]};
    assign start_product      = start_pixel_signed * start_coeff_signed;

    // Products 1..8 are generated from the stored operand words.
    reg [7:0] next_pixel_raw;
    reg [7:0] next_coeff_raw;

    wire signed [8:0] next_pixel_signed;
    wire signed [8:0] next_coeff_signed;
    wire signed [17:0] next_product;

    always @(*) begin
        next_pixel_raw = 8'd0;
        next_coeff_raw = 8'd0;

        case (next_index)
            4'd1: begin
                next_pixel_raw = pixels_reg[15:8];
                next_coeff_raw = kernel_reg[15:8];
            end
            4'd2: begin
                next_pixel_raw = pixels_reg[23:16];
                next_coeff_raw = kernel_reg[23:16];
            end
            4'd3: begin
                next_pixel_raw = pixels_reg[31:24];
                next_coeff_raw = kernel_reg[31:24];
            end
            4'd4: begin
                next_pixel_raw = pixels_reg[39:32];
                next_coeff_raw = kernel_reg[39:32];
            end
            4'd5: begin
                next_pixel_raw = pixels_reg[47:40];
                next_coeff_raw = kernel_reg[47:40];
            end
            4'd6: begin
                next_pixel_raw = pixels_reg[55:48];
                next_coeff_raw = kernel_reg[55:48];
            end
            4'd7: begin
                next_pixel_raw = pixels_reg[63:56];
                next_coeff_raw = kernel_reg[63:56];
            end
            4'd8: begin
                next_pixel_raw = pixels_reg[71:64];
                next_coeff_raw = kernel_reg[71:64];
            end
            default: begin
                next_pixel_raw = 8'd0;
                next_coeff_raw = 8'd0;
            end
        endcase
    end

    assign next_pixel_signed = {1'b0, next_pixel_raw};
    assign next_coeff_signed = {next_coeff_raw[7], next_coeff_raw};
    assign next_product      = next_pixel_signed * next_coeff_signed;

    reg signed [17:0] product_reg;
    reg signed [19:0] accumulator;
    reg               active;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            pixels_reg   <= 72'd0;
            kernel_reg   <= 72'd0;
            next_index   <= 4'd0;
            product_reg  <= 18'sd0;
            accumulator  <= 20'sd0;
            result       <= 20'sd0;
            done         <= 1'b0;
            active       <= 1'b0;
        end

        else begin
            done <= 1'b0;

            if (start && !active) begin
                pixels_reg  <= pixels;
                kernel_reg  <= kernel;

                // Capture product 0 immediately on E0.
                product_reg <= start_product;
                next_index  <= 4'd1;

                accumulator <= 20'sd0;
                active      <= 1'b1;
            end

            else if (active) begin
                if (next_index == 4'd9) begin
                    // E9: accumulate the ninth registered product.
                    result <= accumulator + product_reg;
                    done   <= 1'b1;
                    active <= 1'b0;
                end

                else begin
                    // E1..E8:
                    //   - consume the previously registered product
                    //   - capture the next multiplier result
                    accumulator <= accumulator + product_reg;
                    product_reg <= next_product;
                    next_index  <= next_index + 1'b1;
                end
            end
        end
    end

endmodule
