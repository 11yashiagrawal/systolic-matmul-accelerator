`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for output_buffer (issue #10).
// Checks: reset wins over capture and every address reads 0; nothing loads without
// capture; capture loads all N*N values; values hold while acc_flat changes; a
// second capture replaces them; every address reads back with no clock edge
// needed; reset clears the results. Expected values are written by hand below.
module tb_output_buffer;

    localparam N      = 4;
    localparam ACC_W  = `SA_ACC_W;
    localparam ADDR_W = 4;              // $clog2(16)
    localparam MAX_REPORTED = 10;

    reg                    clk     = 1'b0;
    reg                    rst_n   = 1'b0;
    reg                    capture = 1'b0;
    reg  [N*N*ACC_W-1:0]   acc_flat = 0;
    reg  [ADDR_W-1:0]      c_addr  = 0;
    wire signed [ACC_W-1:0] c_rdata;

    integer n_checks = 0;
    integer n_fail   = 0;

    output_buffer #(.N(N), .ACC_W(ACC_W)) dut (
        .clk(clk), .rst_n(rst_n), .capture(capture),
        .acc_flat(acc_flat), .c_addr(c_addr), .c_rdata(c_rdata)
    );

    always #5 clk = ~clk;

    // Two hand-picked sets of results, including the extremes of 32-bit signed and
    // the max_negative / max_mixed products from spec section 9.
    integer set1 [0:N*N-1];
    integer set2 [0:N*N-1];

    task load_acc(input integer which);
        integer i;
        begin
            for (i = 0; i < N*N; i = i + 1)
                acc_flat[i*ACC_W +: ACC_W] = (which == 1) ? set1[i] : set2[i];
        end
    endtask

    task tick(input c);
        begin
            @(negedge clk);
            capture = c;
            @(posedge clk);
            #1;
            capture = 1'b0;
        end
    endtask

    // Read every address combinationally and compare. which = 0 expects all zeros.
    task read_all(input integer which, input [8*12-1:0] what);
        integer i, expected;
        begin
            for (i = 0; i < N*N; i = i + 1) begin
                c_addr = i;
                #1;
                expected = (which == 0) ? 0 : (which == 1) ? set1[i] : set2[i];
                n_checks = n_checks + 1;
                if (c_rdata !== expected) begin
                    if (n_fail < MAX_REPORTED)
                        $display("  FAIL %0s: c_addr %0d reads %0d, expected %0d", what, i, c_rdata, expected);
                    n_fail = n_fail + 1;
                end
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_output_buffer.vcd");
        $dumpvars(0, tb_output_buffer);

        set1[0]  =  65536;       set1[1]  = -65024;      set1[2]  =  -1;          set1[3]  =  0;
        set1[4]  =  2147483647;  set1[5]  = -2147483647 - 1; set1[6] = 30;       set1[7]  =  70;
        set1[8]  =  110;         set1[9]  =  150;        set1[10] = -846;         set1[11] =  4;
        set1[12] =  123456;      set1[13] = -654321;     set1[14] =  16384;       set1[15] = -16256;

        set2[0]  = -7;           set2[1]  =  8;          set2[2]  = -9;           set2[3]  =  10;
        set2[4]  =  1000000;     set2[5]  = -1000000;    set2[6]  =  42;          set2[7]  = -42;
        set2[8]  =  174;         set2[9]  =  278;        set2[10] =  382;         set2[11] =  446;
        set2[12] =  614;         set2[13] =  846;        set2[14] = -1;           set2[15] =  2;

        // Reset with capture held high and data on acc_flat: reset must win.
        load_acc(1);
        capture = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        capture = 1'b0;
        read_all(0, "reset");
        @(negedge clk);
        rst_n = 1'b1;

        // No capture: nothing loads.
        tick(1'b0);
        tick(1'b0);
        read_all(0, "no capture");

        // capture loads all N*N values at once.
        tick(1'b1);
        read_all(1, "capture 1");

        // acc_flat changes but capture stays low: the results hold.
        load_acc(2);
        tick(1'b0);
        tick(1'b0);
        tick(1'b0);
        read_all(1, "hold");

        // A second capture replaces every value.
        tick(1'b1);
        read_all(2, "capture 2");

        // Reset clears the results.
        @(negedge clk);
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        read_all(0, "reset again");
        @(negedge clk);
        rst_n = 1'b1;

        if (n_fail == 0) begin
            $display("PASS tb_output_buffer %0d/%0d", n_checks, n_checks);
            $finish;
        end else begin
            $display("FAIL tb_output_buffer %0d of %0d checks failed", n_fail, n_checks);
            $fatal(1, "output_buffer mismatch");
        end
    end

endmodule

`default_nettype wire
