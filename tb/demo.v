`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Demo host for `make demo` (issue #70). Not a self-checking testbench: the
// driver, model/demo.py, writes one product to build/demo/, compiles this file
// once for systolic_top and once with -DBASELINE for seq_matmul, and checks the
// C that each run writes back against NumPy.
//
// The host procedure is the one of docs/spec.md section 12: N x N output tiles in
// row-major order, chunks of at most K_MAX along the inner dimension, the first
// chunk a normal run and the rest accumulate runs, rows of A past M and columns of
// B past P written as zero. Each run's writes start in the first DONE cycle of
// the previous run and every tile is read one element per cycle, so the host
// cycles are those of the reference schedule.
//
// Inputs (spec 9.3 formats, one product): build/demo/dims.hex (M, K, P),
// build/demo/a.hex (M*K lines), build/demo/b.hex (K*P lines).
// Outputs: build/demo/c_<design>.hex (M*P lines, row-major) and one line
// "DEMO <design> busy=<b> host=<h> runs=<r> tiles=<t> chunks=<c>".
// With +waves, the last tile is dumped to build/demo/<design>.vcd.
module demo_tb;

    localparam N         = `SA_N;
    localparam DATA_W    = `SA_DATA_W;
    localparam ACC_W     = `SA_ACC_W;
    localparam CYC_W     = `SA_CYC_W;
    localparam K_MAX     = `SA_K_MAX;
    localparam NN        = N * N;
    localparam ADDR_W    = $clog2(NN);
    localparam OP_ADDR_W = $clog2(N * K_MAX);
    localparam K_LEN_W   = $clog2(K_MAX + 1);
    localparam MAX_AB    = 65536;
    localparam MAX_C     = 4096;

    reg                      clk     = 1'b0;
    reg                      rst_n   = 1'b0;
    reg                      a_we    = 1'b0;
    reg  [OP_ADDR_W-1:0]     a_addr  = 0;
    reg  signed [DATA_W-1:0] a_wdata = 0;
    reg                      b_we    = 1'b0;
    reg  [OP_ADDR_W-1:0]     b_addr  = 0;
    reg  signed [DATA_W-1:0] b_wdata = 0;
    reg                      start   = 1'b0;
    reg  [K_LEN_W-1:0]       k_len   = 1;
    reg                      accumulate = 1'b0;
    reg  [ADDR_W-1:0]        c_addr  = 0;
    wire                     busy;
    wire                     done;
    wire signed [ACC_W-1:0]  c_rdata;
    wire [CYC_W-1:0]         cycle_count;

`ifdef BASELINE
    localparam [8*8-1:0] DESIGN = "baseline";
    seq_matmul #(
`else
    localparam [8*8-1:0] DESIGN = "array";
    systolic_top #(
`endif
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

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    reg [31:0]             dims  [0:2];
    reg [DATA_W-1:0]       a_mem [0:MAX_AB-1];
    reg [DATA_W-1:0]       b_mem [0:MAX_AB-1];
    reg signed [ACC_W-1:0] c_out [0:MAX_C-1];
    integer M, KK, P;

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // One run: pulse start and wait for done, counting the busy cycles.
    integer busy_cycles;
    task run_len(input integer len, input integer acc);
        integer guard;
        begin
            k_len      = len;
            accumulate = acc;
            start = 1'b1;
            tick;
            start = 1'b0;
            busy_cycles = 0;
            guard = 0;
            while (done !== 1'b1 && guard < 4*NN*K_MAX) begin
                if (busy === 1'b1)
                    busy_cycles = busy_cycles + 1;
                tick;
                guard = guard + 1;
            end
            if (done !== 1'b1) begin
                $display("DEMO %0s: done never rose", DESIGN);
                $fatal(1, "run did not finish");
            end
        end
    endtask

    integer prod_busy, prod_host, tiles, chunks, waves;
    task run_product;
        integer ti, tj, ch, kl, k0, i, row, col, addr, t0;
        begin
            chunks = (KK + K_MAX - 1) / K_MAX;
            tiles  = ((M + N - 1) / N) * ((P + N - 1) / N);
            prod_busy = 0;
            t0 = cyc;
            for (ti = 0; ti*N < M; ti = ti + 1)
                for (tj = 0; tj*N < P; tj = tj + 1) begin
                    if (waves && (ti + 1)*N >= M && (tj + 1)*N >= P) begin
                        if (DESIGN == "array")
                            $dumpfile("build/demo/array.vcd");
                        else
                            $dumpfile("build/demo/baseline.vcd");
                        $dumpvars(0, demo_tb);
                    end
                    for (ch = 0; ch < chunks; ch = ch + 1) begin
                        k0 = ch * K_MAX;
                        kl = (KK - k0 < K_MAX) ? KK - k0 : K_MAX;
                        for (i = 0; i < N*kl; i = i + 1) begin
                            row = ti*N + i / kl;            // A block element (i / kl, i % kl)
                            col = tj*N + i % N;             // B block element (i / N, i % N)
                            a_we = 1'b1; a_addr = (i / kl)*K_MAX + i % kl;
                            a_wdata = (row < M) ? a_mem[row*KK + k0 + i % kl] : 0;
                            b_we = 1'b1; b_addr = i;
                            b_wdata = (col < P) ? b_mem[(k0 + i / N)*P + col] : 0;
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
                        if (row < M && col < P)
                            c_out[row*P + col] = c_rdata;
                        tick;
                    end
                end
            prod_host = cyc - t0;
        end
    endtask

    integer fd, i;
    initial begin
        waves = $test$plusargs("waves");
        $readmemh("build/demo/dims.hex", dims);
        M  = dims[0];
        KK = dims[1];
        P  = dims[2];
        if (M < 1 || KK < 1 || P < 1 || M*KK > MAX_AB || KK*P > MAX_AB || M*P > MAX_C) begin
            $display("DEMO %0s: product %0dx%0dx%0d is outside this host's storage", DESIGN, M, KK, P);
            $fatal(1, "bad dimensions");
        end
        $readmemh("build/demo/a.hex", a_mem, 0, M*KK - 1);
        $readmemh("build/demo/b.hex", b_mem, 0, KK*P - 1);

        repeat (2) @(posedge clk);
        #1;
        rst_n = 1'b1;
        tick;

        run_product;

        if (DESIGN == "array")
            fd = $fopen("build/demo/c_array.hex", "w");
        else
            fd = $fopen("build/demo/c_baseline.hex", "w");
        for (i = 0; i < M*P; i = i + 1)
            $fdisplay(fd, "%08h", c_out[i]);
        $fclose(fd);
        $display("DEMO %0s busy=%0d host=%0d runs=%0d tiles=%0d chunks=%0d",
                 DESIGN, prod_busy, prod_host, tiles*chunks, tiles, chunks);
        $finish;
    end

endmodule

`default_nettype wire
