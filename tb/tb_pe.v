`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for pe (issue #6).
// Checks the one-cycle forwarding delay, accumulation over K = 4 steps, hold and clear.
module tb_pe;

    localparam DATA_W = `SA_DATA_W;
    localparam ACC_W  = `SA_ACC_W;

    reg                     clk   = 1'b0;
    reg                     rst_n = 1'b0;
    reg                     clear = 1'b0;
    reg                     en    = 1'b0;
    reg signed [DATA_W-1:0] a_in  = 0;
    reg signed [DATA_W-1:0] b_in  = 0;
    wire signed [DATA_W-1:0] a_out;
    wire signed [DATA_W-1:0] b_out;
    wire signed [ACC_W-1:0]  acc;

    integer checks = 0;

    pe #(
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) dut (
        .clk  (clk),
        .rst_n(rst_n),
        .clear(clear),
        .en   (en),
        .a_in (a_in),
        .b_in (b_in),
        .a_out(a_out),
        .b_out(b_out),
        .acc  (acc)
    );

    always #5 clk = ~clk;

    // Drive one cycle, then check a_out, b_out and acc after the rising edge.
    task step(input c, input e, input integer av, input integer bv,
              input integer exp_a, input integer exp_b, input integer exp_acc);
        begin
            @(negedge clk);
            clear = c;
            en    = e;
            a_in  = av;
            b_in  = bv;
            @(posedge clk);
            #1;
            checks = checks + 1;
            if (a_out !== exp_a || b_out !== exp_b || acc !== exp_acc) begin
                $display("FAIL pe check %0d: clear=%b en=%b a_in=%0d b_in=%0d | a_out=%0d(exp %0d) b_out=%0d(exp %0d) acc=%0d(exp %0d)",
                         checks, c, e, av, bv, a_out, exp_a, b_out, exp_b, acc, exp_acc);
                $fatal(1, "pe mismatch");
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_pe.vcd");
        $dumpvars(0, tb_pe);

        // Reset: everything zero.
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        checks = checks + 1;
        if (a_out !== 0 || b_out !== 0 || acc !== 0) begin
            $display("FAIL pe: not zero during reset");
            $fatal(1, "pe reset mismatch");
        end
        @(negedge clk);
        rst_n = 1'b1;

        // Forwarding delay: a_in = 7 sampled at an enabled edge appears on a_out
        // after that same edge (one enabled cycle), and acc takes 7 * 9 = 63.
        step(1'b0, 1'b1, 7, 9, 7, 9, 63);
        // Hold: en low freezes a_out, b_out and acc, even though inputs change.
        step(1'b0, 1'b0, -50, 50, 7, 9, 63);
        // A new operand moves on at the next enabled edge only.
        step(1'b0, 1'b1, -5, 2, -5, 2, 63 + (-5 * 2)); // 63 - 10 = 53

        // Accumulate over K = 4 steps, operands arriving one per enabled cycle:
        // a = 1,2,3,4 and b = 5,6,7,8 -> 5, 5+12=17, 17+21=38, 38+32=70.
        step(1'b1, 1'b0, 0, 0, 0, 0, 0);     // clear first
        step(1'b0, 1'b1, 1, 5, 1, 5, 5);
        step(1'b0, 1'b1, 2, 6, 2, 6, 17);
        step(1'b0, 1'b1, 3, 7, 3, 7, 38);
        step(1'b0, 1'b1, 4, 8, 4, 8, 70);

        // Negative operands: -128 * -128 = 16384, -128 * 127 = -16256.
        step(1'b1, 1'b0, 0, 0, 0, 0, 0);     // clear
        step(1'b0, 1'b1, -128, -128, -128, -128, 16384);
        step(1'b0, 1'b1, -128, 127, -128, 127, 16384 - 16256); // 128

        // Clear mid-chain zeroes acc and both forwarding registers.
        step(1'b1, 1'b0, 0, 0, 0, 0, 0);
        step(1'b0, 1'b1, 6, 6, 6, 6, 36);
        step(1'b1, 1'b1, 3, 3, 0, 0, 0);     // clear wins over en

        $display("PASS tb_pe %0d/%0d", checks, checks);
        $finish;
    end

endmodule

`default_nettype wire
