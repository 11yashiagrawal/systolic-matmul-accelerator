`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Single-MAC sequential baseline (issue #64, docs/spec.md section 11).
//
// Same ports and host protocol as systolic_top, so the same testbenches and the
// demo drive both designs. One multiplier and one adder compute C one element
// at a time, row-major, with K multiply-accumulates per element:
//
//   for row, for col:  sum = 0;  for k: sum += A[row][k] * B[k][col];  C[row][col] = sum
//
// That is one MAC per cycle and N*N*K compute cycles per run, with no CLEAR or
// CAPTURE cycle: the running sum restarts from the new product at k = 0, and the
// finished element is written to C in the same cycle as its last product.
//
//   IDLE --start--> COMPUTE (N*N*K cycles) --> DONE --start--> COMPUTE ...
//
// The arithmetic matches mac.v (spec section 4): the signed product at its
// natural 2*DATA_W width, sign-extended to ACC_W, so both designs give
// bit-identical C.
//
// Unlike systolic_top, C is written element by element during a run, so it is
// valid only while done is high (spec 7.5 lets the array keep the old C readable
// until CAPTURE; keeping it here would need a second N*N result store).

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
    busy,
    done,
    c_addr,
    c_rdata,
    cycle_count
);

    parameter N      = `SA_N;
    parameter DATA_W = `SA_DATA_W;
    parameter ACC_W  = `SA_ACC_W;
    parameter CYC_W  = `SA_CYC_W;

    localparam K      = N;
    localparam NN     = N * N;
    localparam ADDR_W = $clog2(NN);
    localparam IDX_W  = (N > 1) ? $clog2(N) : 1;   // row, col and k counters

    input  wire                     clk;
    input  wire                     rst_n;

    input  wire                     a_we;
    input  wire [ADDR_W-1:0]        a_addr;
    input  wire signed [DATA_W-1:0] a_wdata;

    input  wire                     b_we;
    input  wire [ADDR_W-1:0]        b_addr;
    input  wire signed [DATA_W-1:0] b_wdata;

    input  wire                     start;
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

    // ---- operand and result storage (row-major, spec section 8) -------------

    reg [NN*DATA_W-1:0] a_mem;
    reg [NN*DATA_W-1:0] b_mem;
    reg [NN*ACC_W-1:0]  c_mem;

    wire a_addr_ok = ({{(32-ADDR_W){1'b0}}, a_addr} < NN);
    wire b_addr_ok = ({{(32-ADDR_W){1'b0}}, b_addr} < NN);
    wire c_addr_ok = ({{(32-ADDR_W){1'b0}}, c_addr} < NN);

    // Host writes are ignored while busy, as in systolic_top (spec 6.7).
    always @(posedge clk) begin
        if (!rst_n) begin
            a_mem <= {(NN*DATA_W){1'b0}};
            b_mem <= {(NN*DATA_W){1'b0}};
        end else if (!busy) begin
            if (a_we && a_addr_ok)
                a_mem[a_addr*DATA_W +: DATA_W] <= a_wdata;
            if (b_we && b_addr_ok)
                b_mem[b_addr*DATA_W +: DATA_W] <= b_wdata;
        end
    end

    assign c_rdata = c_addr_ok ? c_mem[c_addr*ACC_W +: ACC_W] : {ACC_W{1'b0}};

    // ---- the single MAC -----------------------------------------------------

    reg [IDX_W-1:0] row;
    reg [IDX_W-1:0] col;
    reg [IDX_W-1:0] k;

    wire last_k   = ({{(32-IDX_W){1'b0}}, k}   == K - 1);
    wire last_col = ({{(32-IDX_W){1'b0}}, col} == N - 1);
    wire last_row = ({{(32-IDX_W){1'b0}}, row} == N - 1);

    // A[row][k] and B[k][col] from the operand stores.
    reg signed [DATA_W-1:0] a_op;
    reg signed [DATA_W-1:0] b_op;
    integer a_idx;
    integer b_idx;
    always @(*) begin
        a_idx = {{(32-IDX_W){1'b0}}, row} * N + {{(32-IDX_W){1'b0}}, k};
        b_idx = {{(32-IDX_W){1'b0}}, k}   * N + {{(32-IDX_W){1'b0}}, col};
        a_op  = a_mem[a_idx*DATA_W +: DATA_W];
        b_op  = b_mem[b_idx*DATA_W +: DATA_W];
    end

    // Natural-width product, sign-extended to ACC_W, as in mac.v.
    wire signed [2*DATA_W-1:0] prod     = a_op * b_op;
    wire signed [ACC_W-1:0]    prod_ext = {{(ACC_W - 2*DATA_W){prod[2*DATA_W-1]}}, prod};

    // Running sum of the current element; it restarts at k = 0.
    reg  signed [ACC_W-1:0] sum;
    wire signed [ACC_W-1:0] sum_next = (k == {IDX_W{1'b0}}) ? prod_ext : sum + prod_ext;

    integer c_idx;
    always @(*) begin
        c_idx = {{(32-IDX_W){1'b0}}, row} * N + {{(32-IDX_W){1'b0}}, col};
    end

    // ---- control ------------------------------------------------------------

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            row         <= {IDX_W{1'b0}};
            col         <= {IDX_W{1'b0}};
            k           <= {IDX_W{1'b0}};
            sum         <= {ACC_W{1'b0}};
            c_mem       <= {(NN*ACC_W){1'b0}};
            cycle_count <= {CYC_W{1'b0}};
        end else begin
            case (state)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        state       <= S_COMPUTE;
                        row         <= {IDX_W{1'b0}};
                        col         <= {IDX_W{1'b0}};
                        k           <= {IDX_W{1'b0}};
                        cycle_count <= {CYC_W{1'b0}};
                    end
                end

                S_COMPUTE: begin
                    cycle_count <= cycle_count + 1'b1;
                    sum         <= sum_next;
                    if (last_k) begin
                        // The element is finished: store it and move to the next.
                        c_mem[c_idx*ACC_W +: ACC_W] <= sum_next;
                        k <= {IDX_W{1'b0}};
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
