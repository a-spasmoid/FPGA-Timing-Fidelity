`timescale 1ns / 1ps

// ============================================================================
// A6 — carry-save accumulator
//
// Difference from A2:
//   Operand storage and explicit 9-way selection remain conventional, but the
//   running accumulation is no longer stored as one ordinary two's-complement
//   number updated through a full carry-propagating addition every cycle.
//   Instead, A6 stores the partial sum in carry-save form as two 20-bit vectors
//   (csa_sum and csa_carry).  Each new signed product is incorporated with
//   bitwise XOR/majority logic, so carry propagation is deferred.
//
// On cycles 0..7 of the nine-MAC sequence, the carry-save representation is
// registered.  On the ninth MAC cycle, the final product is incorporated and
// one carry-propagating addition converts the carry-save representation into
// the normal 20-bit result.
//
// What stays unchanged:
//   - same explicit operand ordering
//   - same one multiplier per cycle
//   - same 9-cycle computation latency / II = 10
//   - same signed 20-bit result
//
// This variant probes ARITHMETIC REPRESENTATION / ACCUMULATOR STRUCTURE rather
// than operand selection.
// ============================================================================

module A6(
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

    reg [3:0] counter;

    reg [7:0] pixel_raw;
    reg [7:0] coeff_raw;

    wire signed [8:0]  pixel_signed;
    wire signed [8:0]  coeff_signed;
    wire signed [17:0] product;

    always @(*) begin
        pixel_raw = 8'd0;
        coeff_raw = 8'd0;

        case (counter)
            4'd0: begin pixel_raw = pixels_reg[7:0];   coeff_raw = kernel_reg[7:0];   end
            4'd1: begin pixel_raw = pixels_reg[15:8];  coeff_raw = kernel_reg[15:8];  end
            4'd2: begin pixel_raw = pixels_reg[23:16]; coeff_raw = kernel_reg[23:16]; end
            4'd3: begin pixel_raw = pixels_reg[31:24]; coeff_raw = kernel_reg[31:24]; end
            4'd4: begin pixel_raw = pixels_reg[39:32]; coeff_raw = kernel_reg[39:32]; end
            4'd5: begin pixel_raw = pixels_reg[47:40]; coeff_raw = kernel_reg[47:40]; end
            4'd6: begin pixel_raw = pixels_reg[55:48]; coeff_raw = kernel_reg[55:48]; end
            4'd7: begin pixel_raw = pixels_reg[63:56]; coeff_raw = kernel_reg[63:56]; end
            4'd8: begin pixel_raw = pixels_reg[71:64]; coeff_raw = kernel_reg[71:64]; end
            default: begin
                pixel_raw = 8'd0;
                coeff_raw = 8'd0;
            end
        endcase
    end

    assign pixel_signed = {1'b0, pixel_raw};
    assign coeff_signed = {coeff_raw[7], coeff_raw};
    assign product      = pixel_signed * coeff_signed;

    // Sign-extend the 18-bit product into the 20-bit accumulator domain.
    wire [19:0] product_ext;
    assign product_ext = {{2{product[17]}}, product};

    // Carry-save representation: numeric value is csa_sum + csa_carry
    // modulo 2^20.  The true convolution result fits safely in signed 20 bits.
    reg [19:0] csa_sum;
    reg [19:0] csa_carry;

    wire [19:0] csa_sum_next;
    wire [19:0] csa_carry_next;
    wire [19:0] csa_final_value;

    assign csa_sum_next =
        csa_sum ^ csa_carry ^ product_ext;

    assign csa_carry_next =
        (
            (csa_sum   & csa_carry)
          | (csa_sum   & product_ext)
          | (csa_carry & product_ext)
        ) << 1;

    // Only the final cycle requires full carry propagation.
    assign csa_final_value = csa_sum_next + csa_carry_next;

    reg active;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            pixels_reg <= 72'd0;
            kernel_reg <= 72'd0;
            counter    <= 4'd0;
            csa_sum    <= 20'd0;
            csa_carry  <= 20'd0;
            result     <= 20'sd0;
            done       <= 1'b0;
            active     <= 1'b0;
        end

        else begin
            done <= 1'b0;

            if (start && !active) begin
                pixels_reg <= pixels;
                kernel_reg <= kernel;

                counter   <= 4'd0;
                csa_sum   <= 20'd0;
                csa_carry <= 20'd0;
                active    <= 1'b1;
            end

            else if (active) begin
                if (counter == 4'd8) begin
                    // Ninth product: finish the CSA step and perform the one
                    // final carry-propagating addition into result.
                    result <= csa_final_value;
                    done   <= 1'b1;
                    active <= 1'b0;
                end

                else begin
                    csa_sum   <= csa_sum_next;
                    csa_carry <= csa_carry_next;
                    counter   <= counter + 1'b1;
                end
            end
        end
    end

endmodule
