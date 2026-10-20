`timescale 1ns / 1ps

module conv_equivalence_tb;

    reg clk;
    reg rst;
    reg start;
    reg [71:0] pixels;
    reg [71:0] kernel;

    wire signed [19:0] r0, r1, r2, r3, r4, r5, r6;
    wire d0, d1, d2, d3, d4, d5, d6;

    integer i;
    integer failures;
    integer seed;

    A0 u0(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r0), .done(d0));

    A1 u1(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r1), .done(d1));

    A2 u2(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r2), .done(d2));

    A3 u3(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r3), .done(d3));

    A4 u4(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r4), .done(d4));

    A5 u5(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r5), .done(d5));

    A6 u6(.clk(clk), .rst(rst), .start(start),
          .pixels(pixels), .kernel(kernel), .result(r6), .done(d6));

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task check_cycle;
        begin
            #1;

            if ((d1 !== d0) ||
                (d2 !== d0) ||
                (d3 !== d0) ||
                (d4 !== d0) ||
                (d5 !== d0) ||
                (d6 !== d0)) begin

                $display(
                    "DONE mismatch at t=%0t: d0=%b d1=%b d2=%b d3=%b d4=%b d5=%b d6=%b",
                    $time, d0, d1, d2, d3, d4, d5, d6
                );
                failures = failures + 1;
            end

            if (d0) begin
                if ((r1 !== r0) ||
                    (r2 !== r0) ||
                    (r3 !== r0) ||
                    (r4 !== r0) ||
                    (r5 !== r0) ||
                    (r6 !== r0)) begin

                    $display(
                        "RESULT mismatch at t=%0t: r0=%0d r1=%0d r2=%0d r3=%0d r4=%0d r5=%0d r6=%0d",
                        $time, r0, r1, r2, r3, r4, r5, r6
                    );
                    failures = failures + 1;
                end
            end
        end
    endtask

    task launch_and_wait;
        input [71:0] p;
        input [71:0] k;
        integer c;
        begin
            @(negedge clk);
            pixels = p;
            kernel = k;
            start  = 1'b1;

            // E0: transaction accepted.
            @(posedge clk);
            check_cycle();

            if (d0 !== 1'b0) begin
                $display("Unexpected done at E0, t=%0t", $time);
                failures = failures + 1;
            end

            @(negedge clk);
            start = 1'b0;

            // E1..E9.
            // Reassert start across E5 while busy; all candidates must ignore it.
            for (c = 1; c <= 9; c = c + 1) begin

                if (c == 5) begin
                    @(negedge clk);
                    start = 1'b1;
                end

                @(posedge clk);
                check_cycle();

                if ((c < 9) && (d0 !== 1'b0)) begin
                    $display("Unexpected early done at E%0d, t=%0t", c, $time);
                    failures = failures + 1;
                end

                if ((c == 9) && (d0 !== 1'b1)) begin
                    $display("Missing done at E9, t=%0t", $time);
                    failures = failures + 1;
                end

                if (c == 5) begin
                    @(negedge clk);
                    start = 1'b0;
                end
            end
        end
    endtask

    initial begin
        failures = 0;
        seed = 32'h5EED1234;

        rst = 1'b0;
        start = 1'b0;
        pixels = 72'd0;
        kernel = 72'd0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b1;

        // Six directed vectors used during hardware bring-up.
        launch_and_wait(
            72'h0102040810204080FF,
            72'h000000000000000001
        );

        launch_and_wait(
            72'h0102040810204080FF,
            72'h010000000000000000
        );

        launch_and_wait(
            72'h010203040506070809,
            72'h09FE07FC05FA03F801
        );

        launch_and_wait(
            72'hFFFFFFFFFFFFFFFFFF,
            72'h7F7F7F7F7F7F7F7F7F
        );

        launch_and_wait(
            72'hFFFFFFFFFFFFFFFFFF,
            72'h808080808080808080
        );

        launch_and_wait(
            72'h00FF01FE02FD03FC04,
            72'h807FFF0102FE40C000
        );

        // Seeded random differential regression.
        for (i = 0; i < 1000; i = i + 1) begin
            launch_and_wait(
                {$random(seed), $random(seed), $random(seed)},
                {$random(seed), $random(seed), $random(seed)}
            );
        end

        if (failures == 0)
            $display(
                "PASS: A0-A6 cycle-equivalent for directed + 1000 seeded random transactions."
            );
        else
            $display("FAIL: %0d mismatches detected.", failures);

        $finish;
    end

endmodule
