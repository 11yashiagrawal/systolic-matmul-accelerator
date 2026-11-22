`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// End-to-end self-checking testbench for systolic_top (issues #11 and #69).
//
// Reads A, B and the expected C from the three golden vector sets (docs/spec.md
// section 9) in sim/vectors/, which `make vectors` creates. Run with
// `make sim-systolic_top`. Expected values come only from the vector files.
//
// Checks: every Phase 1 case with k_len = N (9.1); every K != N case (9.2), with
// the filler past k_len written too; every tiled product (9.3) cut into tiles and
// accumulate chunks through the host ports, as in spec section 12; the handshake
// checks of spec 7.5. Cycle counts go to results/phase1/cycle_counts.csv,
// results/phase2/cycle_counts.csv (K != N runs) and results/phase2/tiled_cycles.csv
// (whole products).
//
// Last line of output: "PASS tb_systolic_top <passed>/<total>", or
// "FAIL tb_systolic_top <failed> of <total> checks failed" followed by $fatal.
module tb_systolic_top;

    localparam N         = `SA_N;
    localparam DATA_W    = `SA_DATA_W;
    localparam ACC_W     = `SA_ACC_W;
    localparam CYC_W     = `SA_CYC_W;
    localparam K         = N;
    localparam K_MAX     = `SA_K_MAX;
    localparam NN        = N * N;
    localparam ADDR_W    = $clog2(NN);
    localparam OP_ADDR_W = $clog2(N * K_MAX);   // A and B ports (spec section 8)
    localparam K_LEN_W   = $clog2(K_MAX + 1);
    localparam BUSY      = K + 2*N;         // busy cycles per run, spec 7.4 (12 for N = 4)
    localparam MAX_CASES = 1024;
    localparam MAX_REPORTED = 10;

    reg                     clk     = 1'b0;
    reg                     rst_n   = 1'b0;
    reg                     a_we    = 1'b0;
    reg  [OP_ADDR_W-1:0]    a_addr  = 0;
    reg  signed [DATA_W-1:0] a_wdata = 0;
    reg                     b_we    = 1'b0;
    reg  [OP_ADDR_W-1:0]    b_addr  = 0;
    reg  signed [DATA_W-1:0] b_wdata = 0;
    reg                     start   = 1'b0;
    // Every case in the Phase 1 set has K = N, so every run uses k_len = N and no
    // accumulate (spec section 9.1).
    reg  [K_LEN_W-1:0]      k_len   = K;
    reg                     accumulate = 1'b0;
    reg  [ADDR_W-1:0]       c_addr  = 0;
    wire                    busy;
    wire                    done;
    wire signed [ACC_W-1:0] c_rdata;
    wire [CYC_W-1:0]        cycle_count;

    systolic_top #(
        .N(N), .K_MAX(K_MAX), .DATA_W(DATA_W), .ACC_W(ACC_W), .CYC_W(CYC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata),
        .start(start), .k_len(k_len), .accumulate(accumulate),
        .busy(busy), .done(done),
        .c_addr(c_addr), .c_rdata(c_rdata), .cycle_count(cycle_count)
    );

    always #5 clk = ~clk;

    // Golden vectors (spec section 9).
    reg [31:0]       cfg   [0:1];
    reg [DATA_W-1:0] a_mem [0:MAX_CASES*NN-1];
    reg [DATA_W-1:0] b_mem [0:MAX_CASES*NN-1];
    reg [ACC_W-1:0]  c_mem [0:MAX_CASES*NN-1];
    integer          n_cases;

    // K != N set (spec 9.2): each case fills all N*K_MAX elements of A and of B,
    // with random filler past k_len.
    localparam KN_MAX_CASES = 256;
    localparam KN_AB        = N * K_MAX;    // lines per case in a.hex and b.hex
    reg [31:0]       kn_cfg  [0:2];
    reg [31:0]       kn_klen [0:KN_MAX_CASES-1];
    reg [DATA_W-1:0] kn_a    [0:KN_MAX_CASES*KN_AB-1];
    reg [DATA_W-1:0] kn_b    [0:KN_MAX_CASES*KN_AB-1];
    reg [ACC_W-1:0]  kn_c    [0:KN_MAX_CASES*NN-1];
    integer          kn_cases;

    // Tiled set (spec 9.3): whole products, back to back in each file.
    localparam TL_MAX_PRODUCTS = 64;
    localparam TL_MAX_AB       = 16384;
    localparam TL_MAX_C        = 4096;
    reg [31:0]       tl_cfg  [0:2];
    reg [31:0]       tl_dims [0:3*TL_MAX_PRODUCTS-1];
    reg [DATA_W-1:0] tl_a    [0:TL_MAX_AB-1];
    reg [DATA_W-1:0] tl_b    [0:TL_MAX_AB-1];
    reg [ACC_W-1:0]  tl_c    [0:TL_MAX_C-1];
    integer          tl_products;

    // Free-running cycle counter, for the host cycles of a whole product.
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

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

    // Address of element e = r*N + k of an N x N matrix A on the A port, where
    // rows are K_MAX apart (spec section 8). B rows are N apart, so B's address is e.
    function integer a_port(input integer e);
        a_port = (e / N) * K_MAX + (e % N);
    endfunction

    // Write case c's A and B through the two write ports, one element per cycle each.
    task load_case(input integer c);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                a_we = 1'b1; a_addr = a_port(addr); a_wdata = a_mem[c*NN + addr];
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
                        a_we = 1'b1; a_addr = a_port(guard % NN); a_wdata = 127 - guard;
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

    // Pulse start with the given k_len and accumulate and wait for done, counting
    // the busy cycles. Both they and cycle_count must equal k_len + 2N, or
    // k_len + 2N - 1 for an accumulate run, which skips CLEAR (spec 7.4 and 7.6).
    integer exp_busy;
    task run_len(input integer len, input integer acc);
        integer guard;
        begin
            k_len      = len;
            accumulate = acc;
            exp_busy   = len + 2*N - (acc ? 1 : 0);
            start = 1'b1;
            tick;                           // start and k_len sampled at this edge
            start = 1'b0;
            busy_cycles = 0;
            guard = 0;
            while (done !== 1'b1 && guard < 10*exp_busy) begin
                if (busy === 1'b1)
                    busy_cycles = busy_cycles + 1;
                tick;
                guard = guard + 1;
            end
            check(done === 1'b1, "done never rose", guard, exp_busy);
            check(busy_cycles == exp_busy, "busy cycles", busy_cycles, exp_busy);
            check(cycle_count == exp_busy, "cycle_count", cycle_count, exp_busy);
            k_len      = K;
            accumulate = 1'b0;
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

    // Names of the K != N cases and the tiled products, for the Phase 2 cycle-count CSVs.
    reg [8*24-1:0] kn_name [0:KN_MAX_CASES-1];
    reg [8*24-1:0] tl_name [0:TL_MAX_PRODUCTS-1];
    task read_set_manifests;
        integer fd, r, idx, f1, f2, f3, f4, f5, f6, f7, f8;
        reg [8*128-1:0] line;
        reg [8*24-1:0]  name;
        begin
            for (idx = 0; idx < KN_MAX_CASES; idx = idx + 1)
                kn_name[idx] = "unnamed";
            for (idx = 0; idx < TL_MAX_PRODUCTS; idx = idx + 1)
                tl_name[idx] = "unnamed";
            // index k_len T busy ab_first_line c_first_line name
            fd = $fopen("sim/vectors/kn/manifest.txt", "r");
            if (fd != 0) begin
                while (!$feof(fd)) begin
                    r = $fgets(line, fd);
                    if (r > 0 && $sscanf(line, "%d %d %d %d %d %d %s",
                                         idx, f1, f2, f3, f4, f5, name) == 7 &&
                        idx >= 0 && idx < KN_MAX_CASES)
                        kn_name[idx] = name;
                end
                $fclose(fd);
            end
            // index M K P tiles chunks a_first b_first c_first name
            fd = $fopen("sim/vectors/tiled/manifest.txt", "r");
            if (fd != 0) begin
                while (!$feof(fd)) begin
                    r = $fgets(line, fd);
                    if (r > 0 && $sscanf(line, "%d %d %d %d %d %d %d %d %d %s",
                                         idx, f1, f2, f3, f4, f5, f6, f7, f8, name) == 10 &&
                        idx >= 0 && idx < TL_MAX_PRODUCTS)
                        tl_name[idx] = name;
                end
                $fclose(fd);
            end
        end
    endtask

    // Load the K != N and tiled sets and check they were made for this N and K_MAX.
    task load_sets;
        integer p, na, nb, nc;
        begin
            $readmemh("sim/vectors/kn/config.hex", kn_cfg);
            kn_cases = kn_cfg[1];
            if (kn_cfg[0] !== N || kn_cfg[2] !== K_MAX || kn_cases < 1 || kn_cases > KN_MAX_CASES) begin
                $display("FAIL tb_systolic_top: kn/config.hex says N = %0d, K_MAX = %0d, %0d cases",
                         kn_cfg[0], kn_cfg[2], kn_cases);
                $fatal(1, "K != N vectors do not match this testbench");
            end
            $readmemh("sim/vectors/kn/klen.hex", kn_klen, 0, kn_cases - 1);
            $readmemh("sim/vectors/kn/a.hex", kn_a, 0, kn_cases*KN_AB - 1);
            $readmemh("sim/vectors/kn/b.hex", kn_b, 0, kn_cases*KN_AB - 1);
            $readmemh("sim/vectors/kn/c.hex", kn_c, 0, kn_cases*NN - 1);

            $readmemh("sim/vectors/tiled/config.hex", tl_cfg);
            tl_products = tl_cfg[1];
            if (tl_cfg[0] !== N || tl_cfg[2] !== K_MAX || tl_products < 1 ||
                tl_products > TL_MAX_PRODUCTS) begin
                $display("FAIL tb_systolic_top: tiled/config.hex says N = %0d, K_MAX = %0d, %0d products",
                         tl_cfg[0], tl_cfg[2], tl_products);
                $fatal(1, "tiled vectors do not match this testbench");
            end
            $readmemh("sim/vectors/tiled/dims.hex", tl_dims, 0, 3*tl_products - 1);
            // The products lie back to back, so the files' lengths are sums of
            // M*K, K*P and M*P.
            na = 0; nb = 0; nc = 0;
            for (p = 0; p < tl_products; p = p + 1) begin
                na = na + tl_dims[3*p] * tl_dims[3*p + 1];
                nb = nb + tl_dims[3*p + 1] * tl_dims[3*p + 2];
                nc = nc + tl_dims[3*p] * tl_dims[3*p + 2];
            end
            if (na > TL_MAX_AB || nb > TL_MAX_AB || nc > TL_MAX_C) begin
                $display("FAIL tb_systolic_top: tiled products need %0d, %0d and %0d lines", na, nb, nc);
                $fatal(1, "tiled vectors larger than this testbench");
            end
            $readmemh("sim/vectors/tiled/a.hex", tl_a, 0, na - 1);
            $readmemh("sim/vectors/tiled/b.hex", tl_b, 0, nb - 1);
            $readmemh("sim/vectors/tiled/c.hex", tl_c, 0, nc - 1);
            read_set_manifests;
            $display("vectors: %0d K != N cases, %0d tiled products", kn_cases, tl_products);
        end
    endtask

    // Write all N*K_MAX elements of K != N case c to A and B, address for address,
    // including the filler past its k_len.
    task load_kn(input integer c);
        integer i;
        begin
            for (i = 0; i < KN_AB; i = i + 1) begin
                a_we = 1'b1; a_addr = i; a_wdata = kn_a[c*KN_AB + i];
                b_we = 1'b1; b_addr = i; b_wdata = kn_b[c*KN_AB + i];
                tick;
            end
            a_we = 1'b0;
            b_we = 1'b0;
        end
    endtask

    task check_kn_c(input integer c);
        integer addr;
        begin
            for (addr = 0; addr < NN; addr = addr + 1) begin
                c_addr = addr;
                #0.1;
                n_checks = n_checks + 1;
                if (c_rdata !== $signed(kn_c[c*NN + addr])) begin
                    if (n_fail < MAX_REPORTED)
                        $display("  FAIL K != N case %0d (k_len %0d): C[%0d][%0d] = %0d, expected %0d",
                                 c, kn_klen[c], addr / N, addr % N, c_rdata, $signed(kn_c[c*NN + addr]));
                    n_fail = n_fail + 1;
                end
                tick;
            end
        end
    endtask

    // Run tiled product p through the host ports (spec section 12): tiles in
    // row-major order, chunks of at most K_MAX, the first chunk a normal run and
    // the rest accumulate runs, rows of A past M and columns of B past P written
    // as zero. Each run's writes start in the first DONE cycle of the previous
    // run, and the tile is read one element per cycle, so prod_host counts the
    // reference host schedule of spec 12.
    integer tl_a0, tl_b0, tl_c0;        // first line of the product in each file
    integer prod_busy, prod_host, prod_tiles, prod_chunks, exp_prod_busy, exp_prod_host;
    task run_product(input integer p);
        integer M, KK, P, ti, tj, ch, kl, k0, i, row, col, addr, t0;
        reg signed [ACC_W-1:0] want;
        begin
            M  = tl_dims[3*p];
            KK = tl_dims[3*p + 1];
            P  = tl_dims[3*p + 2];
            prod_chunks = (KK + K_MAX - 1) / K_MAX;
            prod_tiles  = ((M + N - 1) / N) * ((P + N - 1) / N);
            prod_busy   = 0;
            t0 = cyc;
            for (ti = 0; ti*N < M; ti = ti + 1)
                for (tj = 0; tj*N < P; tj = tj + 1) begin
                    for (ch = 0; ch < prod_chunks; ch = ch + 1) begin
                        k0 = ch * K_MAX;
                        kl = (KK - k0 < K_MAX) ? KK - k0 : K_MAX;
                        for (i = 0; i < N*kl; i = i + 1) begin
                            row = ti*N + i / kl;            // A block element (i / kl, i % kl)
                            col = tj*N + i % N;             // B block element (i / N, i % N)
                            a_we = 1'b1; a_addr = (i / kl)*K_MAX + i % kl;
                            a_wdata = (row < M) ? tl_a[tl_a0 + row*KK + k0 + i % kl] : 0;
                            b_we = 1'b1; b_addr = i;
                            b_wdata = (col < P) ? tl_b[tl_b0 + (k0 + i / N)*P + col] : 0;
                            tick;
                        end
                        a_we = 1'b0;
                        b_we = 1'b0;
                        run_len(kl, ch > 0);
                        prod_busy = prod_busy + busy_cycles;
                    end
                    for (addr = 0; addr < NN; addr = addr + 1) begin
                        c_addr = addr;
                        #0.1;
                        row = ti*N + addr / N;
                        col = tj*N + addr % N;
                        if (row < M && col < P) begin
                            want = tl_c[tl_c0 + row*P + col];
                            n_checks = n_checks + 1;
                            if (c_rdata !== want) begin
                                if (n_fail < MAX_REPORTED)
                                    $display("  FAIL product %0d (%0dx%0dx%0d): C[%0d][%0d] = %0d, expected %0d",
                                             p, M, KK, P, row, col, c_rdata, want);
                                n_fail = n_fail + 1;
                            end
                        end
                        tick;
                    end
                end
            prod_host = cyc - t0;
            // Spec 11.2: per tile, K + chunks*(2N - 1) + 1 busy cycles, and
            // (N + 1)K + 2N*chunks + 1 + N*N host cycles.
            exp_prod_busy = prod_tiles * (KK + prod_chunks*(2*N - 1) + 1);
            exp_prod_host = prod_tiles * ((N + 1)*KK + 2*N*prod_chunks + 1 + NN);
            check(prod_busy == exp_prod_busy, "product busy cycles", prod_busy, exp_prod_busy);
            check(prod_host == exp_prod_host, "product host cycles", prod_host, exp_prod_host);
            tl_a0 = tl_a0 + M*KK;
            tl_b0 = tl_b0 + KK*P;
            tl_c0 = tl_c0 + M*P;
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
        load_sets;

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

        // Every K != N case (spec 9.2), with the filler past k_len written too.
        // compute_cycles is busy_cycles minus CLEAR and CAPTURE, against
        // k_len + 2N - 2 (spec 7.4).
        csv = $fopen("results/phase2/cycle_counts.csv", "w");
        if (csv == 0) begin
            $display("FAIL tb_systolic_top: cannot write results/phase2/cycle_counts.csv");
            $fatal(1, "cannot write cycle counts");
        end
        $fdisplay(csv, "case,name,k_len,accumulate,busy_cycles,cycle_count,expected_busy,compute_cycles,expected_compute");
        for (vc = 0; vc < kn_cases; vc = vc + 1) begin
            load_kn(vc);
            run_len(kn_klen[vc], 0);
            check_kn_c(vc);
            $fdisplay(csv, "%0d,%0s,%0d,0,%0d,%0d,%0d,%0d,%0d", vc, kn_name[vc], kn_klen[vc],
                      busy_cycles, cycle_count, exp_busy, busy_cycles - 2, kn_klen[vc] + 2*N - 2);
        end
        $fclose(csv);
        $display("K != N: %0d cases run, k_len 1 to %0d, every element of C compared; cycle counts in results/phase2/cycle_counts.csv",
                 kn_cases, K_MAX);

        // Every tiled product (spec 9.3), cut into tiles and chunks as in spec 12.
        // One row per product: its busy and host cycles against spec 11.2.
        csv = $fopen("results/phase2/tiled_cycles.csv", "w");
        if (csv == 0) begin
            $display("FAIL tb_systolic_top: cannot write results/phase2/tiled_cycles.csv");
            $fatal(1, "cannot write cycle counts");
        end
        $fdisplay(csv, "product,name,m,k,p,tiles,chunks,runs,busy_cycles,expected_busy,host_cycles,expected_host");
        tl_a0 = 0;
        tl_b0 = 0;
        tl_c0 = 0;
        for (vc = 0; vc < tl_products; vc = vc + 1) begin
            run_product(vc);
            $fdisplay(csv, "%0d,%0s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", vc, tl_name[vc],
                      tl_dims[3*vc], tl_dims[3*vc + 1], tl_dims[3*vc + 2], prod_tiles, prod_chunks,
                      prod_tiles*prod_chunks, prod_busy, exp_prod_busy, prod_host, exp_prod_host);
        end
        $fclose(csv);
        $display("tiled: %0d products run through the host ports, every element of C compared; cycle counts in results/phase2/tiled_cycles.csv",
                 tl_products);

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
