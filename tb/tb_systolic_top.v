`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// End-to-end self-checking testbench for systolic_top (issue #11).
//
// Reads A, B and the expected C from the golden vectors of #14 (docs/spec.md
// section 9) in sim/vectors/, which `make vectors` creates. Run with
// `make sim-systolic_top`. Expected values come only from the vector files.
//
// Last line of output: "PASS tb_systolic_top <passed>/<total>", or
// "FAIL tb_systolic_top <failed> of <total> checks failed" followed by $fatal.
module tb_systolic_top;

    localparam N         = `SA_N;
    localparam DATA_W    = `SA_DATA_W;
    localparam ACC_W     = `SA_ACC_W;
    localparam CYC_W     = `SA_CYC_W;
    localparam K         = N;
    localparam NN        = N * N;
    localparam ADDR_W    = $clog2(NN);
    localparam BUSY      = K + 2*N;         // busy cycles per run, spec 7.4 (12 for N = 4)
    localparam MAX_CASES = 1024;
    localparam MAX_REPORTED = 10;

    reg                     clk     = 1'b0;
    reg                     rst_n   = 1'b0;
    reg                     a_we    = 1'b0;
    reg  [ADDR_W-1:0]       a_addr  = 0;
    reg  signed [DATA_W-1:0] a_wdata = 0;
    reg                     b_we    = 1'b0;
    reg  [ADDR_W-1:0]       b_addr  = 0;
    reg  signed [DATA_W-1:0] b_wdata = 0;
    reg                     start   = 1'b0;
    reg  [ADDR_W-1:0]       c_addr  = 0;
    wire                    busy;
    wire                    done;
    wire signed [ACC_W-1:0] c_rdata;
    wire [CYC_W-1:0]        cycle_count;

    systolic_top #(
        .N(N), .DATA_W(DATA_W), .ACC_W(ACC_W), .CYC_W(CYC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata),
        .start(start), .busy(busy), .done(done),
        .c_addr(c_addr), .c_rdata(c_rdata), .cycle_count(cycle_count)
    );

    always #5 clk = ~clk;

    // Golden vectors (spec section 9).
    reg [31:0]       cfg   [0:1];
    reg [DATA_W-1:0] a_mem [0:MAX_CASES*NN-1];
    reg [DATA_W-1:0] b_mem [0:MAX_CASES*NN-1];
    reg [ACC_W-1:0]  c_mem [0:MAX_CASES*NN-1];
    integer          n_cases;

    // Expected C for the handshake checks, set from a case or worked by hand.
    reg signed [ACC_W-1:0] exp_c [0:NN-1];

    integer n_checks = 0;
    integer n_fail   = 0;

    // ---- helpers -----------------------------------------------------------

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task check(input integer ok, input [8*24-1:0] what, input integer got, input integer expected);
        begin
            n_checks = n_checks + 1;
            if (!ok) begin
                if (n_fail < MAX_REPORTED)
                    $display("  FAIL %0s: got %0d, expected %0d", what, got, expected);
                n_fail = n_fail + 1;
            end
        end
    endtask

    // C is read one element per cycle, as a host does (spec section 8), so the
    // reads show up one address per cycle in the waveform.

    // Every address of C reads zero (after reset).
    task check_c_zero(input [8*24-1:0] what);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                c_addr = addr;
                #0.1;
                check(c_rdata === 0, what, c_rdata, 0);
                tick;
            end
        end
    endtask

    // Write case c's A and B through the two write ports, one element per cycle each.
    task load_case(input integer c);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                a_we = 1'b1; a_addr = addr; a_wdata = a_mem[c*NN + addr];
                b_we = 1'b1; b_addr = addr; b_wdata = b_mem[c*NN + addr];
                tick;
            end
            a_we = 1'b0;
            b_we = 1'b0;
        end
    endtask

    // Write zero to every address of B, leaving A as it is.
    task load_b_zero;
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                b_we = 1'b1; b_addr = addr; b_wdata = 0;
                tick;
            end
            b_we = 1'b0;
        end
    endtask

    // Pulse start for one cycle and wait for done, counting the cycles busy is high.
    // With write_during_run set, the testbench also writes other values to A and B
    // in every busy cycle; the top must ignore them (spec 7.5). With read_old_c
    // set, it reads one address of C in every busy cycle and expects the previous
    // run's C (in exp_c), which stays readable until CAPTURE (spec 7.5).
    integer busy_cycles;
    task run_once(input integer write_during_run, input integer read_old_c);
        integer guard;
        begin
            start = 1'b1;
            tick;                           // start sampled at this edge
            start = 1'b0;
            busy_cycles = 0;
            guard = 0;
            while (done !== 1'b1 && guard < 10*BUSY) begin
                if (busy === 1'b1) begin
                    busy_cycles = busy_cycles + 1;
                    if (read_old_c) begin
                        c_addr = guard % NN;
                        #0.1;
                        check(c_rdata === exp_c[guard % NN], "old C during run",
                              c_rdata, exp_c[guard % NN]);
                    end
                    if (write_during_run) begin
                        a_we = 1'b1; a_addr = guard % NN;       a_wdata = 127 - guard;
                        b_we = 1'b1; b_addr = (guard + 5) % NN; b_wdata = guard - 100;
                    end
                end
                tick;
                guard = guard + 1;
            end
            a_we = 1'b0;
            b_we = 1'b0;
            check(done === 1'b1, "done never rose", guard, BUSY);
            check(busy_cycles == BUSY, "busy cycles", busy_cycles, BUSY);
            check(cycle_count == BUSY, "cycle_count", cycle_count, BUSY);
        end
    endtask

    // Read every address of C and compare it with case c of c.hex.
    task check_c(input integer c);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                c_addr = addr;
                #0.1;
                n_checks = n_checks + 1;
                if (c_rdata !== $signed(c_mem[c*NN + addr])) begin
                    if (n_fail < MAX_REPORTED)
                        $display("  FAIL case %0d: C[%0d][%0d] = %0d, expected %0d",
                                 c, addr / N, addr % N, c_rdata, $signed(c_mem[c*NN + addr]));
                    n_fail = n_fail + 1;
                end
                tick;
            end
        end
    endtask

    task expect_zero;
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1)
                exp_c[addr] = 0;
        end
    endtask

    task expect_case(input integer c);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1)
                exp_c[addr] = $signed(c_mem[c*NN + addr]);
        end
    endtask

    task check_c_exp(input [8*24-1:0] what);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                c_addr = addr;
                #0.1;
                check(c_rdata === exp_c[addr], what, c_rdata, exp_c[addr]);
                tick;
            end
        end
    endtask

    // Read manifest.txt: print the seed line, so the log records the vector seed,
    // and keep each case's name for cycle_counts.csv.
    reg [8*24-1:0] case_name [0:MAX_CASES-1];
    task read_manifest;
        integer fd, seed_val, r, idx, first;
        reg [8*128-1:0] line;
        reg [8*24-1:0]  name;
        begin
            for (idx = 0; idx < MAX_CASES; idx = idx + 1)
                case_name[idx] = "unnamed";
            fd = $fopen("sim/vectors/manifest.txt", "r");
            if (fd == 0) begin
                $display("FAIL tb_systolic_top: cannot open sim/vectors/manifest.txt (run make vectors)");
                $fatal(1, "missing vectors");
            end
            while (!$feof(fd)) begin
                r = $fgets(line, fd);
                if (r > 0 && $sscanf(line, "seed = %d", seed_val) == 1)
                    $display("vectors: seed = %0d", seed_val);
                else if (r > 0 && $sscanf(line, "%d %d %s", idx, first, name) == 3 &&
                         idx >= 0 && idx < MAX_CASES)
                    case_name[idx] = name;
            end
            $fclose(fd);
        end
    endtask

    // ---- the test sequence -------------------------------------------------

    integer vc;
    integer csv;

    initial begin
        $dumpfile("build/tb_systolic_top.vcd");
        $dumpvars(0, tb_systolic_top);

        // Load the vectors and check they were made for this N.
        $readmemh("sim/vectors/config.hex", cfg);
        n_cases = cfg[1];
        $display("vectors: N = %0d, cases = %0d", cfg[0], n_cases);
        read_manifest;
        if (cfg[0] !== N || n_cases < 1 || n_cases > MAX_CASES) begin
            $display("FAIL tb_systolic_top: config.hex says N = %0d with %0d cases; this testbench has N = %0d",
                     cfg[0], n_cases, N);
            $fatal(1, "vectors do not match this testbench");
        end
        $readmemh("sim/vectors/a.hex", a_mem, 0, n_cases*NN - 1);
        $readmemh("sim/vectors/b.hex", b_mem, 0, n_cases*NN - 1);
        $readmemh("sim/vectors/c.hex", c_mem, 0, n_cases*NN - 1);

        // Reset: every address of C reads 0 and cycle_count is 0 (spec 7.5).
        repeat (2) @(posedge clk);
        #1;
        check(cycle_count === 0, "reset cycle_count", cycle_count, 0);
        check(busy === 1'b0 && done === 1'b0, "reset busy/done", {busy, done}, 0);
        check_c_zero("reset C");
        rst_n = 1'b1;
        tick;

        // Every case in the vectors: directed cases 0-5, then the random ones.
        // One row per run goes to cycle_counts.csv. busy_cycles is measured from
        // start to done; compute_cycles is busy_cycles minus the one CLEAR and one
        // CAPTURE cycle of spec 7.3, to compare with the K + 2N - 2 formula.
        csv = $fopen("results/phase1/cycle_counts.csv", "w");
        if (csv == 0) begin
            $display("FAIL tb_systolic_top: cannot write results/phase1/cycle_counts.csv");
            $fatal(1, "cannot write cycle counts");
        end
        $fdisplay(csv, "case,name,busy_cycles,cycle_count,expected_busy,compute_cycles,expected_compute");
        for (vc = 0; vc < n_cases; vc = vc + 1) begin
            load_case(vc);
            run_once(0, 0);
            check_c(vc);
            $fdisplay(csv, "%0d,%0s,%0d,%0d,%0d,%0d,%0d", vc, case_name[vc], busy_cycles,
                      cycle_count, BUSY, busy_cycles - 2, K + 2*N - 2);
        end
        $fclose(csv);
        $display("cases: %0d run, every element of C compared; cycle counts in results/phase1/cycle_counts.csv",
                 n_cases);

        // Writes during a run are ignored (spec 7.5, section 10): load the known
        // case, write other values to A and B in every busy cycle, and C must
        // still be the known product.
        load_case(5);
        expect_case(5);
        run_once(1, 0);
        check_c_exp("C after writes in run");

        // Back-to-back runs: start again from DONE without reloading. A and B keep
        // their contents and the writes above were not taken, so C is the same.
        run_once(0, 0);
        check_c_exp("C back-to-back run");
        run_once(0, 0);
        check_c_exp("C third run");
        $display("handshake: writes during a run ignored, back-to-back runs checked");

        // Replace one matrix, and C stays readable until CAPTURE (spec 7.5): after
        // the identity case (C = A), write zeros to B only. The next run reads the
        // old C in every busy cycle, then C is zero (A x 0, worked by hand).
        load_case(0);
        expect_case(0);
        run_once(0, 0);
        check_c_exp("C identity case");
        load_b_zero;
        run_once(0, 1);
        expect_zero;
        check_c_exp("C after B replaced");

        // Reset in the middle of a run (spec 7.5): with the known product in C,
        // start a run and pull rst_n low for one edge after five busy cycles.
        load_case(5);
        expect_case(5);
        run_once(0, 0);
        check_c_exp("C before reset");
        start = 1'b1;
        tick;
        start = 1'b0;
        repeat (5) tick;
        rst_n = 1'b0;
        tick;
        check(cycle_count === 0, "mid-run reset cycle_count", cycle_count, 0);
        check(busy === 1'b0 && done === 1'b0, "mid-run reset busy/done", {busy, done}, 0);
        check_c_zero("C after mid-run reset");
        rst_n = 1'b1;
        tick;
        // Reset zeroed A and B as well, so a run with no new writes gives C = 0.
        expect_zero;
        run_once(0, 0);
        check_c_exp("C run after reset");
        $display("handshake: C readable until CAPTURE, one matrix replaced, reset mid-run checked");

        if (n_fail == 0) begin
            $display("PASS tb_systolic_top %0d/%0d", n_checks, n_checks);
            $finish;
        end else begin
            $display("FAIL tb_systolic_top %0d of %0d checks failed", n_fail, n_checks);
            $fatal(1, "systolic_top does not match the golden vectors");
        end
    end

endmodule

`default_nettype wire
