`timescale 1ns / 1ps

module A3(
    input clk,
    input rst,
    input start,
    input [71:0] pixels,
    input [71:0] kernel,
    output reg signed [19:0] result,
    output reg done
    );

    // Nine 9-bit operands instead of nine 8-bit operands
    reg [80:0] pixels_reg;
    reg [80:0] kernel_reg;

    reg [3:0] counter;

    // Operands are already extended before selection
    reg signed [8:0] pixel_signed;
    reg signed [8:0] coeff_signed;

    wire signed [17:0] product;

    assign product = pixel_signed * coeff_signed;

    reg signed [19:0] accumulator;
    reg active;

    // Explicitly select one of the already-extended operands
    always @(*) begin
        pixel_signed = 9'sd0;
        coeff_signed = 9'sd0;

        case (counter)
            4'd0: begin
                pixel_signed = pixels_reg[8:0];
                coeff_signed = kernel_reg[8:0];
            end

            4'd1: begin
                pixel_signed = pixels_reg[17:9];
                coeff_signed = kernel_reg[17:9];
            end

            4'd2: begin
                pixel_signed = pixels_reg[26:18];
                coeff_signed = kernel_reg[26:18];
            end

            4'd3: begin
                pixel_signed = pixels_reg[35:27];
                coeff_signed = kernel_reg[35:27];
            end

            4'd4: begin
                pixel_signed = pixels_reg[44:36];
                coeff_signed = kernel_reg[44:36];
            end

            4'd5: begin
                pixel_signed = pixels_reg[53:45];
                coeff_signed = kernel_reg[53:45];
            end

            4'd6: begin
                pixel_signed = pixels_reg[62:54];
                coeff_signed = kernel_reg[62:54];
            end

            4'd7: begin
                pixel_signed = pixels_reg[71:63];
                coeff_signed = kernel_reg[71:63];
            end

            4'd8: begin
                pixel_signed = pixels_reg[80:72];
                coeff_signed = kernel_reg[80:72];
            end

            default: begin
                pixel_signed = 9'sd0;
                coeff_signed = 9'sd0;
            end
        endcase
    end

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            counter     <= 0;
            accumulator <= 0;
            result      <= 0;
            done        <= 0;
            active      <= 0;
        end

        else begin
            done <= 0;

            if (start && !active) begin

                // Pixels are unsigned, so zero-extend from 8 to 9 bits
                pixels_reg[8:0]   <= {1'b0, pixels[7:0]};
                pixels_reg[17:9]  <= {1'b0, pixels[15:8]};
                pixels_reg[26:18] <= {1'b0, pixels[23:16]};
                pixels_reg[35:27] <= {1'b0, pixels[31:24]};
                pixels_reg[44:36] <= {1'b0, pixels[39:32]};
                pixels_reg[53:45] <= {1'b0, pixels[47:40]};
                pixels_reg[62:54] <= {1'b0, pixels[55:48]};
                pixels_reg[71:63] <= {1'b0, pixels[63:56]};
                pixels_reg[80:72] <= {1'b0, pixels[71:64]};

                // Kernel coefficients are signed, so sign-extend
                kernel_reg[8:0]   <= {kernel[7],  kernel[7:0]};
                kernel_reg[17:9]  <= {kernel[15], kernel[15:8]};
                kernel_reg[26:18] <= {kernel[23], kernel[23:16]};
                kernel_reg[35:27] <= {kernel[31], kernel[31:24]};
                kernel_reg[44:36] <= {kernel[39], kernel[39:32]};
                kernel_reg[53:45] <= {kernel[47], kernel[47:40]};
                kernel_reg[62:54] <= {kernel[55], kernel[55:48]};
                kernel_reg[71:63] <= {kernel[63], kernel[63:56]};
                kernel_reg[80:72] <= {kernel[71], kernel[71:64]};

                counter     <= 0;
                accumulator <= 0;
                active      <= 1;
            end

            else if (active) begin
                if (counter == 8) begin
                    result <= accumulator + product;
                    done   <= 1;
                    active <= 0;
                end

                else begin
                    counter     <= counter + 1;
                    accumulator <= accumulator + product;
                end
            end
        end
    end

endmodule
