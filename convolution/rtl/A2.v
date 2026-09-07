`timescale 1ns / 1ps

module A2(
    input clk,
    input rst,
    input start,
    input [71:0] pixels,
    input [71:0] kernel,
    output reg signed [19:0] result,
    output reg done
    );
    
    reg [71:0] pixels_reg;
    reg [71:0] kernel_reg;
    
    reg [3:0] counter;
    
    wire signed [8:0] pixel_signed;
    wire signed [8:0] coeff_signed;
    
    wire signed [17:0] product;
    
    reg [7:0] pixel_raw;
    reg [7:0] coeff_raw;
    
    always @(*) begin
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
    
    assign product = pixel_signed * coeff_signed;

    reg signed [19:0] accumulator;
    
    reg active;
    
    always@(posedge(clk) or negedge(rst))
    begin
        if(!rst)
        begin
            counter     <= 0;
            accumulator <= 0;
            result      <= 0;
            done        <= 0;
            active      <= 0;
        end
        
        else 
        begin
            done <= 0;
            
            if(start && !active)
            begin
                pixels_reg <= pixels;
                kernel_reg <= kernel;
                
                counter     <= 0;
                accumulator <= 0;
                active      <= 1;
            end      
              
            else if(active)
            begin
                if(counter == 8)
                begin
                    result <= accumulator + product;
                    done   <= 1;
                    active <= 0;
                end
                
                else
                begin
                    counter <= counter+1;                            
                    accumulator <= product + accumulator;
                end
            end        
        end
    end

endmodule      
