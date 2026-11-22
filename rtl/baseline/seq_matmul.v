`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Single-MAC sequential baseline (issue #64, docs/spec.md section 6.8).
//
// Same parameters, ports, address map and host protocol as systolic_top, so the
// same testbenches and the demo drive both designs. One multiplier and one adder
// compute C one element at a time, row-major, with k_len multiply-accumulates per
// element:
//
//   for row, for col:  sum = s0;  for k < k_len: sum += A[row][k] * B[k][col];  C[row][col] = sum
//
// where s0 is 0 for a normal run and the stored C[row][col] for an accumulate
// run. That is one MAC per cycle and N*N*k_len busy cycles per run, with no clear
// or capture cycle: the running sum restarts at k = 0, and the finished element is
// written to C in the same cycle as its last product.
//
//   IDLE --start--> COMPUTE (N*N*k_len cycles) --> DONE --start--> COMPUTE ...
//
// k_len and accumulate are sampled with start and held for the run; a start whose
// k_len is 0 or above K_MAX is ignored. The arithmetic matches mac.v (spec section
// 4): the signed product at its natural 2*DATA_W width, sign-extended to ACC_W, so
// both designs give bit-identical C.
//
// Unlike systolic_top, C is written element by element during a run, so it is
// valid from done until the next start (spec 6.8); keeping the old C readable
// would need a second N*N result store.

module seq_matmul (
    clk,
    rst_n,
    a_we,
    a_addr,
    a_wdata,
    b_we,
    b_addr,
    b_wdata,
    start,
    k_len,
    accumulate,
    busy,
    done,
    c_addr,
    c_rdata,
    cycle_count
);

    parameter N      = `SA_N;
    parameter K_MAX  = `SA_K_MAX;
    parameter DATA_W = `SA_DATA_W;
    parameter ACC_W  = `SA_ACC_W;
    parameter CYC_W  = `SA_CYC_W;

    localparam NN        = N * N;
    localparam DEPTH     = N * K_MAX;                  // elements of A, and of B
    localparam OP_ADDR_W = $clog2(DEPTH);
    localparam ADDR_W    = $clog2(NN);
    localparam K_LEN_W   = $clog2(K_MAX + 1);          // holds 0 to K_MAX
    localparam IDX_W     = $clog2(N);                  // row and col counters (N >= 2)
    localparam K_IDX_W   = $clog2(K_MAX);              // k counter (K_MAX >= N >= 2)

    input  wire                     clk;
    input  wire                     rst_n;

    input  wire                     a_we;
    input  wire [OP_ADDR_W-1:0]     a_addr;
    input  wire signed [DATA_W-1:0] a_wdata;

    input  wire                     b_we;
    input  wire [OP_ADDR_W-1:0]     b_addr;
    input  wire signed [DATA_W-1:0] b_wdata;

    input  wire                     start;
    input  wire [K_LEN_W-1:0]       k_len;
    input  wire                     accumulate;
    output wire                     busy;
    output wire                     done;

    input  wire [ADDR_W-1:0]        c_addr;
    output wire signed [ACC_W-1:0]  c_rdata;
    output reg  [CYC_W-1:0]         cycle_count;

    localparam [1:0] S_IDLE    = 2'd0,
                     S_COMPUTE = 2'd1,
                     S_DONE    = 2'd2;

    reg [1:0] state;

    assign busy = (state == S_COMPUTE);
    assign done = (state == S_DONE);

    // ---- operand and result storage (spec section 8) ------------------------
    //   A[r][k] at r*K_MAX + k,  B[k][c] at k*N + c,  C[r][c] at r*N + c

    reg [DEPTH*DATA_W-1:0] a_mem;
    reg [DEPTH*DATA_W-1:0] b_mem;
    reg [NN*ACC_W-1:0]     c_mem;

    wire a_addr_ok = ({{(32-OP_ADDR_W){1'b0}}, a_addr} < DEPTH);
    wire b_addr_ok = ({{(32-OP_ADDR_W){1'b0}}, b_addr} < DEPTH);
    wire c_addr_ok = ({{(32-ADDR_W){1'b0}},    c_addr} < NN);

    // Host writes are ignored while busy, as in systolic_top (spec 6.7).
    always @(posedge clk) begin
        if (!rst_n) begin
            a_mem <= {(DEPTH*DATA_W){1'b0}};
            b_mem <= {(DEPTH*DATA_W){1'b0}};
        end else if (!busy) begin
            if (a_we && a_addr_ok)
                a_mem[a_addr*DATA_W +: DATA_W] <= a_wdata;
            if (b_we && b_addr_ok)
                b_mem[b_addr*DATA_W +: DATA_W] <= b_wdata;
        end
    end

    assign c_rdata = c_addr_ok ? c_mem[c_addr*ACC_W +: ACC_W] : {ACC_W{1'b0}};

    // ---- run parameters, sampled with start ---------------------------------

    reg [K_LEN_W-1:0] run_k_len;
    reg               run_acc;

    wire [31:0] k_len_32 = {{(32-K_LEN_W){1'b0}}, k_len};
    wire        k_len_ok = (k_len_32 >= 32'd1) && (k_len_32 <= K_MAX);
    wire        go       = start && k_len_ok;

    // ---- the single MAC -----------------------------------------------------

    reg [IDX_W-1:0]   row;
    reg [IDX_W-1:0]   col;
    reg [K_IDX_W-1:0] k;

    wire last_k   = ({{(32-K_IDX_W){1'b0}}, k} + 32'd1 == {{(32-K_LEN_W){1'b0}}, run_k_len});
    wire last_col = ({{(32-IDX_W){1'b0}}, col} == N - 1);
    wire last_row = ({{(32-IDX_W){1'b0}}, row} == N - 1);

    // A[row][k], B[k][col] and C[row][col] from the stores.
    reg signed [DATA_W-1:0] a_op;
    reg signed [DATA_W-1:0] b_op;
    reg signed [ACC_W-1:0]  c_old;
    integer a_idx;
    integer b_idx;
    integer c_idx;
    always @(*) begin
        a_idx = {{(32-IDX_W){1'b0}}, row} * K_MAX + {{(32-K_IDX_W){1'b0}}, k};
        b_idx = {{(32-K_IDX_W){1'b0}}, k} * N     + {{(32-IDX_W){1'b0}}, col};
        c_idx = {{(32-IDX_W){1'b0}}, row} * N     + {{(32-IDX_W){1'b0}}, col};
        a_op  = a_mem[a_idx*DATA_W +: DATA_W];
        b_op  = b_mem[b_idx*DATA_W +: DATA_W];
        c_old = c_mem[c_idx*ACC_W +: ACC_W];
    end

    // Natural-width product, sign-extended to ACC_W, as in mac.v.
    wire signed [2*DATA_W-1:0] prod     = a_op * b_op;
    wire signed [ACC_W-1:0]    prod_ext = {{(ACC_W - 2*DATA_W){prod[2*DATA_W-1]}}, prod};

    // Running sum of the current element. At k = 0 it restarts from zero, or from
    // the element's stored value in an accumulate run.
    reg  signed [ACC_W-1:0] sum;
    wire signed [ACC_W-1:0] sum_base = (k == {K_IDX_W{1'b0}}) ? (run_acc ? c_old : {ACC_W{1'b0}})
                                                              : sum;
    wire signed [ACC_W-1:0] sum_next = sum_base + prod_ext;

    // ---- control ------------------------------------------------------------

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            row         <= {IDX_W{1'b0}};
            col         <= {IDX_W{1'b0}};
            k           <= {K_IDX_W{1'b0}};
            sum         <= {ACC_W{1'b0}};
            run_k_len   <= {K_LEN_W{1'b0}};
            run_acc     <= 1'b0;
            c_mem       <= {(NN*ACC_W){1'b0}};
            cycle_count <= {CYC_W{1'b0}};
        end else begin
            case (state)
                S_IDLE, S_DONE: begin
                    if (go) begin
                        state       <= S_COMPUTE;
                        run_k_len   <= k_len;
                        run_acc     <= accumulate;
                        row         <= {IDX_W{1'b0}};
                        col         <= {IDX_W{1'b0}};
                        k           <= {K_IDX_W{1'b0}};
                        cycle_count <= {CYC_W{1'b0}};
                    end
                end

                S_COMPUTE: begin
                    cycle_count <= cycle_count + 1'b1;
                    sum         <= sum_next;
                    if (last_k) begin
                        // The element is finished: store it and move to the next.
                        c_mem[c_idx*ACC_W +: ACC_W] <= sum_next;
                        k <= {K_IDX_W{1'b0}};
                        if (last_col) begin
                            col <= {IDX_W{1'b0}};
                            if (last_row) begin
                                row   <= {IDX_W{1'b0}};
                                state <= S_DONE;
                            end else begin
                                row <= row + 1'b1;
                            end
                        end else begin
                            col <= col + 1'b1;
                        end
                    end else begin
                        k <= k + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
