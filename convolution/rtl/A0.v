`timescale 1ns / 1ps

module A0(
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
    
    wire [7:0] pixel_raw;
    wire [7:0] coeff_raw;
    
    wire signed [8:0] pixel_signed;
    wire signed [8:0] coeff_signed;
    
    wire signed [17:0] product;
    
    assign pixel_raw = pixels_reg[counter*8 +: 8];
    assign coeff_raw = kernel_reg[counter*8 +: 8];
    
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
