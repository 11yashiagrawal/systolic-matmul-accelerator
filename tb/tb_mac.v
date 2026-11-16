`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for mac (issue #6).
// Expected values are worked out by hand in the comments, never taken from the RTL.
module tb_mac;

    localparam DATA_W = `SA_DATA_W;
    localparam ACC_W  = `SA_ACC_W;

    reg                     clk   = 1'b0;
    reg                     rst_n = 1'b0;
    reg                     clear = 1'b0;
    reg                     en    = 1'b0;
    reg signed [DATA_W-1:0] a     = 0;
    reg signed [DATA_W-1:0] b     = 0;
    wire signed [ACC_W-1:0] acc;

    integer checks = 0;

    mac #(
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .clear(clear),
        .en   (en),
        .a    (a),
        .b    (b),
        .acc  (acc)
    );

    always #5 clk = ~clk;

    // Drive one cycle: set inputs after a falling edge, sample acc after the rising edge.
    task step(input c, input e, input integer av, input integer bv, input integer expect_acc);
        begin
            @(negedge clk);
            clear = c;
            en    = e;
            a     = av;
            b     = bv;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (acc !== expect_acc) begin
                $display("FAIL mac check %0d: clear=%b en=%b a=%0d b=%0d acc=%0d expected=%0d",
                         checks, c, e, av, bv, acc, expect_acc);
                $fatal(1, "mac mismatch");
            end
        end
    endtask

    // Single product from a cleared accumulator.
    task product_from_zero(input integer av, input integer bv, input integer expect_acc);
        begin
            step(1'b1, 1'b0, 0, 0, 0);          // clear
            step(1'b0, 1'b1, av, bv, expect_acc); // one accumulate
        end
    endtask

    initial begin
        $dumpfile("build/tb_mac.vcd");
        $dumpvars(0, tb_mac);

        // Reset: acc must be zero while rst_n is low.
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        checks = checks + 1;
        if (acc !== 0) begin
            $display("FAIL mac: acc not zero during reset, acc=%0d", acc);
            $fatal(1, "mac reset mismatch");
        end
        @(negedge clk);
        rst_n = 1'b1;

        // Sign combinations, one product each.
        product_from_zero( 3,    5,  15);     // positive x positive
        product_from_zero(-3,    5, -15);     // negative x positive
        product_from_zero(-4,   -6,  24);     // negative x negative
        product_from_zero(-128, -128, 16384); // most negative x most negative
        product_from_zero(-128,  127, -16256); // most negative x most positive

        // Accumulation chain: 1 + 6 - 20 + 16129 + 16384 = 32500
        step(1'b1, 1'b0, 0, 0, 0);            // clear
        step(1'b0, 1'b1,   1,   1,      1);   // 1*1       -> 1
        step(1'b0, 1'b1,   2,   3,      7);   // 2*3       -> 7
        step(1'b0, 1'b1,  -4,   5,     -13);  // -4*5      -> -13
        step(1'b0, 1'b1, 127, 127,  16116);   // 127*127   -> 16116
        step(1'b0, 1'b1,-128,-128,  32500);   // -128*-128 -> 32500
        step(1'b0, 1'b0, 100, 100,  32500);   // en low: hold, operands ignored

        // Clear in the middle of a chain: clear wins over en in the same cycle.
        step(1'b1, 1'b1,  10,  10,      0);   // clear with en high -> 0
        step(1'b0, 1'b1,   7,  -2,    -14);   // 7*-2 after the clear -> -14

        $display("PASS tb_mac %0d/%0d", checks, checks);
        $finish;
    end

endmodule

`default_nettype wire
