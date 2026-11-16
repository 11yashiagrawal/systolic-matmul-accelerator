`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for sa_controller (issue #7).
//
// Two controllers run side by side on the same start pulses: N = 4 (T = 10) and
// N = 3 (T = 7). Each cycle is checked against the state table in docs/spec.md
// section 7.3 and the cycle-by-cycle trace in section 7.4:
//   r = 0      IDLE (after reset)
//   r = 1      CLEAR
//   r = 2..T+1 COMPUTE, step = r - 2, en high, cycle_count = r - 1
//   r = T+2    CAPTURE, cycle_count = T + 1
//   r >= T+3   DONE, cycle_count = T + 2 (= K + 2N)
module tb_sa_controller;

    reg        clk   = 1'b0;
    reg        rst_n = 1'b0;
    reg        start = 1'b0;

    wire        busy4, done4, clear4, en4, capture4;
    wire [3:0]  step4;
    wire [31:0] cc4;

    wire        busy3, done3, clear3, en3, capture3;
    wire [2:0]  step3;
    wire [31:0] cc3;

    integer checks = 0;

    sa_controller #(.N(4), .CYC_W(32)) dut4 (
        .clk(clk), .rst_n(rst_n), .start(start),
        .busy(busy4), .done(done4), .clear(clear4), .en(en4),
        .step(step4), .capture(capture4), .cycle_count(cc4)
    );

    sa_controller #(.N(3), .CYC_W(32)) dut3 (
        .clk(clk), .rst_n(rst_n), .start(start),
        .busy(busy3), .done(done3), .clear(clear3), .en(en3),
        .step(step3), .capture(capture3), .cycle_count(cc3)
    );

    always #5 clk = ~clk;

    // Compare one controller (which = 4 or 3) against the expected trace at cycle r.
    task check_run(input integer which, input integer r, input integer T);
        integer gb, gd, gc, gen, gcap, gs, gcc;
        integer eb, ed, ec, een, ecap, es, ecc;
        begin
            if (which == 4) begin
                gb = busy4; gd = done4; gc = clear4; gen = en4; gcap = capture4;
                gs = step4; gcc = cc4;
            end else begin
                gb = busy3; gd = done3; gc = clear3; gen = en3; gcap = capture3;
                gs = step3; gcc = cc3;
            end

            if (r == 0) begin
                eb = 0; ed = 0; ec = 0; een = 0; ecap = 0; es = 0; ecc = 0;
            end else if (r == 1) begin
                eb = 1; ed = 0; ec = 1; een = 0; ecap = 0; es = 0; ecc = 0;
            end else if (r <= T + 1) begin
                eb = 1; ed = 0; ec = 0; een = 1; ecap = 0; es = r - 2; ecc = r - 1;
            end else if (r == T + 2) begin
                eb = 1; ed = 0; ec = 0; een = 0; ecap = 1; es = 0; ecc = T + 1;
            end else begin
                eb = 0; ed = 1; ec = 0; een = 0; ecap = 0; es = 0; ecc = T + 2;
            end

            checks = checks + 1;
            if (gb !== eb || gd !== ed || gc !== ec || gen !== een || gcap !== ecap ||
                gs !== es || gcc !== ecc) begin
                $display("FAIL N=%0d r=%0d: got busy=%0d done=%0d clear=%0d en=%0d capture=%0d step=%0d cc=%0d",
                         which, r, gb, gd, gc, gen, gcap, gs, gcc);
                $display("                  expected busy=%0d done=%0d clear=%0d en=%0d capture=%0d step=%0d cc=%0d",
                         eb, ed, ec, een, ecap, es, ecc);
                $fatal(1, "sa_controller mismatch");
            end
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

    // One full run from IDLE or DONE. The start pulse is sampled at the end of cycle 0.
    // ignored_r: if non-zero, start is held high during cycle ignored_r and must be ignored.
    task run_both(input integer ignored_r);
        integer r;
        begin
            tick(1'b1);                                   // cycle 0 ends: start sampled
            for (r = 1; r <= 13; r = r + 1) begin
                if (r > 1)
                    tick((r == ignored_r) ? 1'b1 : 1'b0);  // move into cycle r
                check_run(4, r, 10);
                check_run(3, r, 7);
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_sa_controller.vcd");
        $dumpvars(0, tb_sa_controller);

        // Reset: both controllers idle with zero outputs.
        rst_n = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        check_run(4, 0, 10);
        check_run(3, 0, 7);
        @(negedge clk);
        rst_n = 1'b1;

        // Run 1: start is also high during COMPUTE (cycle 6, step 4), so it must be ignored.
        run_both(6);

        // Run 2: start in DONE begins a new run at once (back-to-back).
        run_both(0);

        // Reset in the middle of a run returns both controllers to IDLE with zero counters.
        tick(1'b1);                  // enter CLEAR
        tick(1'b0);                  // COMPUTE
        tick(1'b0);                  // COMPUTE
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        check_run(4, 0, 10);
        check_run(3, 0, 7);
        @(negedge clk);
        rst_n = 1'b1;

        $display("PASS tb_sa_controller %0d/%0d", checks, checks);
        $finish;
    end

endmodule

`default_nettype wire
