`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for input_skew_buffer (issue #10).
//
// Two N = 4 buffers run side by side: COLUMN_LANES = 0 (A) and COLUMN_LANES = 1 (B).
// Expected lanes are spec table 7.2 transcribed by hand below: for every step t and
// lane l, the address of the element that must be on the lane, or -1 for zero.
// Checks: reset (with a write attempted during reset), writes to every address,
// zeros while en is low, every lane in every step 0..T-1, an overwrite, and reset
// clearing the storage.
module tb_input_skew_buffer;

    localparam N      = 4;
    localparam DATA_W = `SA_DATA_W;
    localparam K      = N;
    localparam T      = K + 2*N - 2;    // 10
    localparam ADDR_W = 4;              // $clog2(16)
    localparam STEP_W = 4;              // $clog2(10)
    localparam MAX_REPORTED = 10;

    reg                     clk   = 1'b0;
    reg                     rst_n = 1'b0;
    reg                     en    = 1'b0;
    reg  [STEP_W-1:0]       step  = 0;
    reg                     we_a  = 1'b0, we_b = 1'b0;
    reg  [ADDR_W-1:0]       waddr_a = 0, waddr_b = 0;
    reg  signed [DATA_W-1:0] wdata_a = 0, wdata_b = 0;
    wire [N*DATA_W-1:0]     lanes_a, lanes_b;

    integer n_checks = 0;
    integer n_fail   = 0;

    input_skew_buffer #(.N(N), .DATA_W(DATA_W), .COLUMN_LANES(0)) dut_a (
        .clk(clk), .rst_n(rst_n), .we(we_a), .waddr(waddr_a), .wdata(wdata_a),
        .en(en), .step(step), .lanes(lanes_a)
    );

    input_skew_buffer #(.N(N), .DATA_W(DATA_W), .COLUMN_LANES(1)) dut_b (
        .clk(clk), .rst_n(rst_n), .we(we_b), .waddr(waddr_b), .wdata(wdata_b),
        .en(en), .step(step), .lanes(lanes_b)
    );

    always #5 clk = ~clk;

    // Matrix contents, row-major. Distinct values, including -128 and 127.
    integer a_val [0:N*N-1];
    integer b_val [0:N*N-1];

    // Spec table 7.2: element address on lane l at step t, or -1 for zero.
    integer exp_a [0:T*N-1];
    integer exp_b [0:T*N-1];

    task row_a(input integer t, input integer e0, input integer e1, input integer e2, input integer e3);
        begin
            exp_a[t*N+0] = e0; exp_a[t*N+1] = e1; exp_a[t*N+2] = e2; exp_a[t*N+3] = e3;
        end
    endtask

    task row_b(input integer t, input integer e0, input integer e1, input integer e2, input integer e3);
        begin
            exp_b[t*N+0] = e0; exp_b[t*N+1] = e1; exp_b[t*N+2] = e2; exp_b[t*N+3] = e3;
        end
    endtask

    task check_lane(input integer which, input integer t, input integer l, input integer expected);
        integer got;
        begin
            if (which == 0) got = $signed(lanes_a[l*DATA_W +: DATA_W]);
            else            got = $signed(lanes_b[l*DATA_W +: DATA_W]);
            n_checks = n_checks + 1;
            if (got !== expected) begin
                if (n_fail < MAX_REPORTED)
                    $display("  FAIL %s step %0d lane %0d: got %0d, expected %0d",
                             (which == 0) ? "A" : "B", t, l, got, expected);
                n_fail = n_fail + 1;
            end
        end
    endtask

    // Check every lane of both buffers at step t. use_table = 0 expects all zeros.
    task check_step(input integer t, input integer use_table);
        integer l, ia, ib;
        begin
            step = t;
            #1;
            for (l = 0; l < N; l = l + 1) begin
                ia = (use_table && t < T) ? exp_a[t*N+l] : -1;
                ib = (use_table && t < T) ? exp_b[t*N+l] : -1;
                check_lane(0, t, l, (ia < 0) ? 0 : a_val[ia]);
                check_lane(1, t, l, (ib < 0) ? 0 : b_val[ib]);
            end
        end
    endtask

    task sweep(input integer use_table, input integer last_step);
        integer t;
        begin
            for (t = 0; t <= last_step; t = t + 1)
                check_step(t, use_table);
        end
    endtask

    task write_both(input integer addr);
        begin
            @(negedge clk);
            we_a = 1'b1; waddr_a = addr; wdata_a = a_val[addr];
            we_b = 1'b1; waddr_b = addr; wdata_b = b_val[addr];
            @(posedge clk);
            #1;
            we_a = 1'b0;
            we_b = 1'b0;
        end
    endtask

    integer idx;

    initial begin
        $dumpfile("build/tb_input_skew_buffer.vcd");
        $dumpvars(0, tb_input_skew_buffer);

        // A[r][c] at r*4 + c, and B likewise.
        a_val[0]  =   11; a_val[1]  =  -22; a_val[2]  =   33; a_val[3]  =  -44;
        a_val[4]  =   55; a_val[5]  = -128; a_val[6]  =   66; a_val[7]  =  -77;
        a_val[8]  =   88; a_val[9]  =  -99; a_val[10] =  127; a_val[11] =    1;
        a_val[12] =   -1; a_val[13] =   17; a_val[14] =  -34; a_val[15] =   51;

        b_val[0]  =   -5; b_val[1]  =   10; b_val[2]  =  -15; b_val[3]  =   20;
        b_val[4]  =  -25; b_val[5]  =   30; b_val[6]  =  127; b_val[7]  =   40;
        b_val[8]  =  -45; b_val[9]  = -128; b_val[10] =  -55; b_val[11] =   60;
        b_val[12] =  -65; b_val[13] =   70; b_val[14] =  -75; b_val[15] =   80;

        // Table 7.2 for A: lane i carries A[i][t-i]; A[r][c] is at r*4 + c.
        row_a(0,  0, -1, -1, -1);   // A00  .    .    .
        row_a(1,  1,  4, -1, -1);   // A01  A10  .    .
        row_a(2,  2,  5,  8, -1);   // A02  A11  A20  .
        row_a(3,  3,  6,  9, 12);   // A03  A12  A21  A30
        row_a(4, -1,  7, 10, 13);   // .    A13  A22  A31
        row_a(5, -1, -1, 11, 14);   // .    .    A23  A32
        row_a(6, -1, -1, -1, 15);   // .    .    .    A33
        row_a(7, -1, -1, -1, -1);
        row_a(8, -1, -1, -1, -1);
        row_a(9, -1, -1, -1, -1);

        // Table 7.2 for B: lane j carries B[t-j][j]; B[r][c] is at r*4 + c.
        row_b(0,  0, -1, -1, -1);   // B00  .    .    .
        row_b(1,  4,  1, -1, -1);   // B10  B01  .    .
        row_b(2,  8,  5,  2, -1);   // B20  B11  B02  .
        row_b(3, 12,  9,  6,  3);   // B30  B21  B12  B03
        row_b(4, -1, 13, 10,  7);   // .    B31  B22  B13
        row_b(5, -1, -1, 14, 11);   // .    .    B32  B23
        row_b(6, -1, -1, -1, 15);   // .    .    .    B33
        row_b(7, -1, -1, -1, -1);
        row_b(8, -1, -1, -1, -1);
        row_b(9, -1, -1, -1, -1);

        // Reset, with a write attempted during reset: reset must win.
        we_a = 1'b1; waddr_a = 0; wdata_a = 8'sd99;
        we_b = 1'b1; waddr_b = 0; wdata_b = 8'sd99;
        repeat (2) @(posedge clk);
        #1;
        we_a = 1'b0; we_b = 1'b0;
        @(negedge clk);
        rst_n = 1'b1;
        en = 1'b1;
        sweep(0, 15);                   // storage is zero, so every lane is zero

        // Write every address of both matrices.
        en = 1'b0;
        for (idx = 0; idx < N*N; idx = idx + 1)
            write_both(idx);

        // en low: every lane is zero in every step.
        en = 1'b0;
        sweep(0, T - 1);

        // en high: every lane in every step matches table 7.2; steps past T-1 are zero.
        en = 1'b1;
        sweep(1, 15);

        // Overwrite one element of each matrix and check the whole table again.
        a_val[6] = -100;                // A[1][2], on lane 1 in step 3
        b_val[9] =   99;                // B[2][1], on lane 1 in step 3
        @(negedge clk);
        we_a = 1'b1; waddr_a = 6; wdata_a = a_val[6];
        we_b = 1'b1; waddr_b = 9; wdata_b = b_val[9];
        @(posedge clk);
        #1;
        we_a = 1'b0; we_b = 1'b0;
        sweep(1, T - 1);

        // Reset clears the storage.
        @(negedge clk);
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        @(negedge clk);
        rst_n = 1'b1;
        sweep(0, T - 1);

        if (n_fail == 0) begin
            $display("PASS tb_input_skew_buffer %0d/%0d", n_checks, n_checks);
            $finish;
        end else begin
            $display("FAIL tb_input_skew_buffer %0d of %0d checks failed", n_fail, n_checks);
            $fatal(1, "input_skew_buffer does not match spec table 7.2");
        end
    end

endmodule

`default_nettype wire
