`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Self-checking testbench for the sequential baseline seq_matmul (issue #64).
//
// Drives seq_matmul through the same host ports as tb_systolic_top and reads the
// same golden vectors (docs/spec.md section 9) from sim/vectors/, which
// `make vectors` creates. Run with `make sim-seq_matmul`. Expected values come
// only from the vector files.
//
// Last line of output: "PASS tb_seq_matmul <passed>/<total>", or
// "FAIL tb_seq_matmul <failed> of <total> checks failed" followed by $fatal.
module tb_seq_matmul;

    localparam N         = `SA_N;
    localparam DATA_W    = `SA_DATA_W;
    localparam ACC_W     = `SA_ACC_W;
    localparam CYC_W     = `SA_CYC_W;
    localparam K         = N;
    localparam NN        = N * N;
    localparam ADDR_W    = $clog2(NN);
    localparam BUSY      = N * N * K;       // busy cycles per run, one MAC per cycle (64 for N = 4)
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

    seq_matmul #(
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

    // Pulse start for one cycle and wait for done, counting the cycles busy is high.
    integer busy_cycles;
    task run_once;
        integer guard;
        begin
            start = 1'b1;
            tick;                           // start sampled at this edge
            start = 1'b0;
            busy_cycles = 0;
            guard = 0;
            while (done !== 1'b1 && guard < 2*BUSY) begin
                if (busy === 1'b1)
                    busy_cycles = busy_cycles + 1;
                tick;
                guard = guard + 1;
            end
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

    // Print the seed line of manifest.txt, so the log records the vector seed.
    task read_manifest;
        integer fd, seed_val, r;
        reg [8*128-1:0] line;
        begin
            fd = $fopen("sim/vectors/manifest.txt", "r");
            if (fd == 0) begin
                $display("FAIL tb_seq_matmul: cannot open sim/vectors/manifest.txt (run make vectors)");
                $fatal(1, "missing vectors");
            end
            while (!$feof(fd)) begin
                r = $fgets(line, fd);
                if (r > 0 && $sscanf(line, "seed = %d", seed_val) == 1)
                    $display("vectors: seed = %0d", seed_val);
            end
            $fclose(fd);
        end
    endtask

    // ---- the test sequence -------------------------------------------------

    integer vc;

    initial begin
        $dumpfile("build/tb_seq_matmul.vcd");
        $dumpvars(0, tb_seq_matmul);

        // Load the vectors and check they were made for this N.
        $readmemh("sim/vectors/config.hex", cfg);
        n_cases = cfg[1];
        $display("vectors: N = %0d, cases = %0d", cfg[0], n_cases);
        read_manifest;
        if (cfg[0] !== N || n_cases < 1 || n_cases > MAX_CASES) begin
            $display("FAIL tb_seq_matmul: config.hex says N = %0d with %0d cases; this testbench has N = %0d",
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
        for (vc = 0; vc < n_cases; vc = vc + 1) begin
            load_case(vc);
            run_once;
            check_c(vc);
        end
        $display("cases: %0d run, every element of C compared", n_cases);

        if (n_fail == 0) begin
            $display("PASS tb_seq_matmul %0d/%0d", n_checks, n_checks);
            $finish;
        end else begin
            $display("FAIL tb_seq_matmul %0d of %0d checks failed", n_fail, n_checks);
            $fatal(1, "seq_matmul does not match the golden vectors");
        end
    end

endmodule

`default_nettype wire
