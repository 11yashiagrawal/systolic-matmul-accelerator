`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for input_skew_buffer (issues #10 and #68).
//
// Phase 1 part: two N = 4 buffers with K_MAX = N and k_len = N run side by side:
// COLUMN_LANES = 0 (A) and COLUMN_LANES = 1 (B). Expected lanes are spec table 7.2
// transcribed by hand below: for every step t and lane l, the address of the
// element that must be on the lane, or -1 for zero. Checks: reset (with a write
// attempted during reset), writes to every address, zeros while en is low, every
// lane in every step 0..T-1, an overwrite, and reset clearing the storage.
//
// Phase 2 part (skew_klen_check, below): A and B buffers with K_MAX > N, for
// N = 4, K_MAX = 16 and N = 3, K_MAX = 5, checked in every step for k_len = 1, N,
// N + 1 and K_MAX against spec section 6.4: lane l carries element k = t - l when
// 0 <= k < k_len, and zero otherwise, while every stored element is nonzero.
module tb_input_skew_buffer;

    localparam N      = 4;
    localparam DATA_W = `SA_DATA_W;
    localparam K      = N;
    localparam T      = K + 2*N - 2;    // 10
    localparam ADDR_W = 4;              // $clog2(16)
    localparam STEP_W = 4;              // $clog2(10)
    localparam K_LEN_W = 3;              // $clog2(K + 1)
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

    input_skew_buffer #(.N(N), .K_MAX(K), .DATA_W(DATA_W), .COLUMN_LANES(0)) dut_a (
        .clk(clk), .rst_n(rst_n), .we(we_a), .waddr(waddr_a), .wdata(wdata_a),
        .en(en), .step(step), .k_len(K[K_LEN_W-1:0]), .lanes(lanes_a)
    );

    input_skew_buffer #(.N(N), .K_MAX(K), .DATA_W(DATA_W), .COLUMN_LANES(1)) dut_b (
        .clk(clk), .rst_n(rst_n), .we(we_b), .waddr(waddr_b), .wdata(wdata_b),
        .en(en), .step(step), .k_len(K[K_LEN_W-1:0]), .lanes(lanes_b)
    );

    always #5 clk = ~clk;

    // Phase 2: K_MAX > N, every k_len from the issue.
    skew_klen_check #(.N(4), .K_MAX(16), .DATA_W(DATA_W)) u_n4_k16 (.clk(clk));
    skew_klen_check #(.N(3), .K_MAX(5), .DATA_W(DATA_W)) u_n3_k5 (.clk(clk));

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

        // Wait for the Phase 2 checks and add their counts.
        wait (u_n4_k16.finished && u_n3_k5.finished);
        n_checks = n_checks + u_n4_k16.n_checks + u_n3_k5.n_checks;
        n_fail   = n_fail   + u_n4_k16.n_fail   + u_n3_k5.n_fail;

        if (n_fail == 0) begin
            $display("PASS tb_input_skew_buffer %0d/%0d", n_checks, n_checks);
            $finish;
        end else begin
            $display("FAIL tb_input_skew_buffer %0d of %0d checks failed", n_fail, n_checks);
            $fatal(1, "input_skew_buffer does not match spec table 7.2 or the k_len rule");
        end
    end

endmodule

// One A buffer and one B buffer with the given N and K_MAX. Every address is
// written with a distinct non-zero value, so a lane that reads the wrong element,
// or an element past k_len, shows up as a mismatch.
module skew_klen_check (clk);

    parameter N      = 4;
    parameter K_MAX  = 16;
    parameter DATA_W = 8;

    localparam DEPTH  = N * K_MAX;
    localparam T_MAX  = K_MAX + 2*N - 2;
    localparam OP_ADDR_W = $clog2(DEPTH);
    localparam STEP_W = $clog2(T_MAX);
    localparam K_LEN_W = $clog2(K_MAX + 1);
    localparam MAX_REPORTED = 10;

    input wire clk;

    reg                      rst_n = 1'b0;
    reg                      en    = 1'b0;
    reg  [STEP_W-1:0]        step  = 0;
    reg  [K_LEN_W-1:0]        k_len = 0;
    reg                      we    = 1'b0;
    reg  [OP_ADDR_W-1:0]     waddr = 0;
    reg  signed [DATA_W-1:0] wdata_a = 0, wdata_b = 0;
    wire [N*DATA_W-1:0]      lanes_a, lanes_b;

    integer n_checks = 0;
    integer n_fail   = 0;
    reg     finished = 1'b0;

    input_skew_buffer #(.N(N), .K_MAX(K_MAX), .DATA_W(DATA_W), .COLUMN_LANES(0)) dut_a (
        .clk(clk), .rst_n(rst_n), .we(we), .waddr(waddr), .wdata(wdata_a),
        .en(en), .step(step), .k_len(k_len), .lanes(lanes_a)
    );

    input_skew_buffer #(.N(N), .K_MAX(K_MAX), .DATA_W(DATA_W), .COLUMN_LANES(1)) dut_b (
        .clk(clk), .rst_n(rst_n), .we(we), .waddr(waddr), .wdata(wdata_b),
        .en(en), .step(step), .k_len(k_len), .lanes(lanes_b)
    );

    // Distinct non-zero values in [-127, 127]; A and B use different sequences.
    integer a_val [0:DEPTH-1];
    integer b_val [0:DEPTH-1];

    function integer val(input integer addr, input integer mul, input integer add);
        begin
            val = ((addr * mul + add) % 255) - 127;
            if (val == 0)
                val = 127;
        end
    endfunction

    task check_lane(input integer which, input integer kl, input integer t,
                    input integer l, input integer expected);
        integer got;
        begin
            if (which == 0) got = $signed(lanes_a[l*DATA_W +: DATA_W]);
            else            got = $signed(lanes_b[l*DATA_W +: DATA_W]);
            n_checks = n_checks + 1;
            if (got !== expected) begin
                if (n_fail < MAX_REPORTED)
                    $display("  FAIL N=%0d K_MAX=%0d %s k_len %0d step %0d lane %0d: got %0d, expected %0d",
                             N, K_MAX, (which == 0) ? "A" : "B", kl, t, l, got, expected);
                n_fail = n_fail + 1;
            end
        end
    endtask

    // Every step the step input can hold. use_rule = 0 expects all zeros.
    // A: lane l carries A[l][k], at l*K_MAX + k.  B: lane l carries B[k][l], at k*N + l.
    task sweep(input integer kl, input integer use_rule);
        integer t, l, k, ea, eb;
        begin
            for (t = 0; t < (1 << STEP_W); t = t + 1) begin
                step = t;
                #1;
                for (l = 0; l < N; l = l + 1) begin
                    k  = t - l;
                    ea = 0;
                    eb = 0;
                    if (use_rule && k >= 0 && k < kl) begin
                        ea = a_val[l*K_MAX + k];
                        eb = b_val[k*N + l];
                    end
                    check_lane(0, kl, t, l, ea);
                    check_lane(1, kl, t, l, eb);
                end
            end
        end
    endtask

    integer idx;

    initial begin
        for (idx = 0; idx < DEPTH; idx = idx + 1) begin
            a_val[idx] = val(idx, 37, 11);
            b_val[idx] = val(idx, 53, 7);
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Write every address of both buffers.
        for (idx = 0; idx < DEPTH; idx = idx + 1) begin
            @(negedge clk);
            we = 1'b1; waddr = idx; wdata_a = a_val[idx]; wdata_b = b_val[idx];
        end
        // Addresses past the storage (when DEPTH is not a power of two) are ignored.
        for (idx = DEPTH; idx < (1 << OP_ADDR_W); idx = idx + 1) begin
            @(negedge clk);
            we = 1'b1; waddr = idx; wdata_a = 8'sd99; wdata_b = 8'sd99;
        end
        @(negedge clk);
        we = 1'b0;

        // en low: zero for every k_len.
        k_len = K_MAX;
        sweep(K_MAX, 0);

        en = 1'b1;
        k_len = 1;      sweep(1, 1);
        k_len = N;      sweep(N, 1);
        k_len = N + 1;  sweep(N + 1, 1);
        k_len = K_MAX;  sweep(K_MAX, 1);

        // k_len = 0 feeds nothing.
        k_len = 0;      sweep(0, 0);

        finished = 1'b1;
    end

endmodule

`default_nettype wire
