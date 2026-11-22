`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for sa_controller (issues #7 and #65).
//
// Two controllers run side by side on the same start pulses: N = 4 with K_MAX = 16
// and N = 3 with K_MAX = 5. Each has its own k_len; accumulate is shared. Every
// cycle of a run is checked against the state table in docs/spec.md section 7.3
// and the trace in section 7.4, with T = k_len + 2N - 2:
//
//   normal run (accumulate low)        accumulate run (skips CLEAR)
//   r = 1      CLEAR                   -
//   r = 2..T+1 COMPUTE, step = r - 2   r = 1..T COMPUTE, step = r - 1
//   r = T+2    CAPTURE                 r = T+1  CAPTURE
//   r >= T+3   DONE, cc = T + 2        r >= T+2 DONE, cc = T + 1
//
// cycle_count (cc) counts every busy cycle, and run_k_len holds the k_len
// sampled with start. The Phase 1 runs (k_len = N, accumulate low) come first and
// are the same checks as before.
module tb_sa_controller;

    localparam KMAX4 = 16;
    localparam KMAX3 = 5;

    reg        clk        = 1'b0;
    reg        rst_n      = 1'b0;
    reg        start      = 1'b0;
    reg        accumulate = 1'b0;
    reg [4:0]  k4         = 5'd4;   // $clog2(KMAX4 + 1) = 5 bits
    reg [2:0]  k3         = 3'd3;   // $clog2(KMAX3 + 1) = 3 bits

    wire        busy4, done4, clear4, en4, capture4;
    wire [4:0]  step4;              // $clog2(16 + 8 - 2) = 5 bits
    wire [4:0]  rk4;
    wire [31:0] cc4;

    wire        busy3, done3, clear3, en3, capture3;
    wire [3:0]  step3;              // $clog2(5 + 6 - 2) = 4 bits
    wire [2:0]  rk3;
    wire [31:0] cc3;

    integer checks = 0;

    sa_controller #(.N(4), .K_MAX(KMAX4), .CYC_W(32)) dut4 (
        .clk(clk), .rst_n(rst_n), .start(start), .k_len(k4), .accumulate(accumulate),
        .busy(busy4), .done(done4), .clear(clear4), .en(en4),
        .step(step4), .run_k_len(rk4), .capture(capture4), .cycle_count(cc4)
    );

    sa_controller #(.N(3), .K_MAX(KMAX3), .CYC_W(32)) dut3 (
        .clk(clk), .rst_n(rst_n), .start(start), .k_len(k3), .accumulate(accumulate),
        .busy(busy3), .done(done3), .clear(clear3), .en(en3),
        .step(step3), .run_k_len(rk3), .capture(capture3), .cycle_count(cc3)
    );

    always #5 clk = ~clk;

    // Compare one controller (which = 4 or 3) with the given expected outputs.
    task check(input integer which, input [255:0] what, input integer r,
               input integer eb, input integer ed, input integer ec, input integer een,
               input integer ecap, input integer es, input integer erk, input integer ecc);
        integer gb, gd, gc, gen, gcap, gs, grk, gcc;
        begin
            if (which == 4) begin
                gb = busy4; gd = done4; gc = clear4; gen = en4; gcap = capture4;
                gs = step4; grk = rk4; gcc = cc4;
            end else begin
                gb = busy3; gd = done3; gc = clear3; gen = en3; gcap = capture3;
                gs = step3; grk = rk3; gcc = cc3;
            end

            checks = checks + 1;
            if (gb !== eb || gd !== ed || gc !== ec || gen !== een || gcap !== ecap ||
                gs !== es || grk !== erk || gcc !== ecc) begin
                $display("FAIL N=%0d %0s r=%0d: got busy=%0d done=%0d clear=%0d en=%0d capture=%0d step=%0d run_k_len=%0d cc=%0d",
                         which, what, r, gb, gd, gc, gen, gcap, gs, grk, gcc);
                $display("      expected busy=%0d done=%0d clear=%0d en=%0d capture=%0d step=%0d run_k_len=%0d cc=%0d",
                         eb, ed, ec, een, ecap, es, erk, ecc);
                $fatal(1, "sa_controller mismatch");
            end
        end
    endtask

    // Cycle r of a run with inner length klen (r = 1 is the first cycle after the start edge).
    task check_run(input integer which, input integer r, input integer klen, input integer acc);
        integer T;
        integer c;   // r counted as if the run had a CLEAR cycle
        begin
            T = klen + 2*which - 2;
            c = acc ? r + 1 : r;
            if (!acc && c == 1)
                check(which, "CLEAR", r, 1, 0, 1, 0, 0, 0, klen, 0);
            else if (c <= T + 1)
                check(which, "COMPUTE", r, 1, 0, 0, 1, 0, c - 2, klen, acc ? c - 2 : c - 1);
            else if (c == T + 2)
                check(which, "CAPTURE", r, 1, 0, 0, 0, 1, 0, klen, acc ? T : T + 1);
            else
                check(which, "DONE", r, 0, 1, 0, 0, 0, 0, klen, acc ? T + 1 : T + 2);
        end
    endtask

    // After reset: IDLE, every output and counter zero.
    task check_reset;
        begin
            check(4, "reset", 0, 0, 0, 0, 0, 0, 0, 0, 0);
            check(3, "reset", 0, 0, 0, 0, 0, 0, 0, 0, 0);
        end
    endtask

    // Advance one clock: drive start before the rising edge, then settle after it.
    task tick(input s);
        begin
            @(negedge clk);
            start = s;
            @(posedge clk);
            #1;
        end
    endtask

    // One full run of both controllers from IDLE or DONE, with k_len kl4 / kl3.
    //   ignored_r: if non-zero, start is held high during cycle ignored_r and must be ignored.
    //   change_r:  if non-zero, k_len and accumulate change during cycle change_r and
    //              must not affect the run.
    task run_both(input integer kl4, input integer kl3, input integer acc,
                  input integer ignored_r, input integer change_r);
        integer r;
        integer last;
        integer t4;
        integer t3;
        begin
            @(negedge clk);
            k4         = kl4;
            k3         = kl3;
            accumulate = acc;
            tick(1'b1);                                   // cycle 0 ends: start sampled
            t4   = kl4 + 6;
            t3   = kl3 + 4;
            last = ((t4 > t3) ? t4 : t3) + 3;             // both reach DONE
            for (r = 1; r <= last; r = r + 1) begin
                if (r > 1) begin
                    if (r == change_r) begin
                        k4         = 5'd1;
                        k3         = 3'd1;
                        accumulate = !acc;
                    end
                    tick((r == ignored_r) ? 1'b1 : 1'b0);  // move into cycle r
                end
                check_run(4, r, kl4, acc);
                check_run(3, r, kl3, acc);
            end
        end
    endtask

    // A start with an out-of-range k_len is ignored: every output holds.
    task bad_start(input integer kl4, input integer kl3,
                   input integer ed, input integer erk4, input integer erk3,
                   input integer ecc4, input integer ecc3);
        begin
            @(negedge clk);
            k4 = kl4;
            k3 = kl3;
            tick(1'b1);
            check(4, "bad k_len", 1, 0, ed, 0, 0, 0, 0, erk4, ecc4);
            check(3, "bad k_len", 1, 0, ed, 0, 0, 0, 0, erk3, ecc3);
            tick(1'b0);
            check(4, "bad k_len", 2, 0, ed, 0, 0, 0, 0, erk4, ecc4);
            check(3, "bad k_len", 2, 0, ed, 0, 0, 0, 0, erk3, ecc3);
        end
    endtask

    initial begin
        $dumpfile("build/tb_sa_controller.vcd");
        $dumpvars(0, tb_sa_controller);

        // Reset: both controllers idle with zero outputs.
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        check_reset;
        @(negedge clk);
        rst_n = 1'b1;

        // Phase 1 runs: k_len = N, accumulate low.
        // Run 1: start is also high during COMPUTE (cycle 6), so it must be ignored.
        run_both(4, 3, 0, 6, 0);
        // Run 2: start in DONE begins a new run at once (back-to-back).
        run_both(4, 3, 0, 0, 0);

        // Shortest and longest runs; in the longest, k_len and accumulate change mid-run.
        run_both(1, 1, 0, 0, 0);
        run_both(KMAX4, KMAX3, 0, 0, 3);

        // Accumulate run from DONE: no CLEAR, busy for T + 1 cycles.
        run_both(KMAX4, KMAX3, 1, 0, 0);
        run_both(1, 1, 1, 4, 0);

        // Out-of-range k_len from DONE: 0 and K_MAX + 1 are ignored.
        // The last run had k_len = 1, so DONE holds run_k_len = 1 and cc = T + 1 = 2N.
        bad_start(0, 0, 1, 1, 1, 8, 6);
        bad_start(KMAX4 + 1, KMAX3 + 1, 1, 1, 1, 8, 6);
        bad_start(31, 7, 1, 1, 1, 8, 6);

        // Reset in the middle of a run returns both controllers to IDLE with zero counters.
        @(negedge clk);
        k4 = 5'd4;
        k3 = 3'd3;
        accumulate = 1'b0;
        tick(1'b1);                  // enter CLEAR
        tick(1'b0);                  // COMPUTE
        tick(1'b0);                  // COMPUTE
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        check_reset;
        @(negedge clk);
        rst_n = 1'b1;

        // Out-of-range k_len from IDLE is ignored too.
        bad_start(0, 0, 0, 0, 0, 0, 0);
        bad_start(KMAX4 + 1, KMAX3 + 1, 0, 0, 0, 0, 0);

        // Accumulate run from IDLE.
        run_both(4, 3, 1, 0, 0);

        $display("PASS tb_sa_controller %0d/%0d", checks, checks);
        $finish;
    end

endmodule

`default_nettype wire
