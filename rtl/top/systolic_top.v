// Top-level systolic-array accelerator: the matrix data interface (issue #4).
// Contract: docs/spec.md sections 6.7 and 7.
//
// The host writes A and B one element at a time (row-major addresses), pulses
// start, waits for done and then reads C one element at a time:
//
//   a_we/a_addr/a_wdata --> input_skew_buffer (A, COLUMN_LANES = 0) --a_left--+
//   b_we/b_addr/b_wdata --> input_skew_buffer (B, COLUMN_LANES = 1) --b_top---+
//                                                                              v
//   start --> sa_controller --clear, en--> systolic_array --acc_flat--> output_buffer --> c_rdata
//                  |  en, step to both buffers               capture -------^
//                  +--> busy, done, cycle_count
//
// The buffers' lanes are combinational in step, so in compute step t lane i of
// A carries A[i][t-i] straight into PE (i, 0), and lane j of B carries B[t-j][j]
// into PE (0, j). The last term reaches PE (N-1, N-1) in step T-1, the controller
// copies the accumulators in CAPTURE, and C is readable from DONE on.
//
// Host writes are ANDed with !busy, so a write during a run cannot change the
// operands in flight. Between runs A and B keep their contents, so a host can
// replace one matrix and start again.

`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

module systolic_top (
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
    localparam T      = K + 2*N - 2;      // compute cycles (10 for N = 4)
    localparam ADDR_W = $clog2(N*N);
    localparam STEP_W = $clog2(T);
    localparam K_LEN_W = $clog2(K + 1);

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
    output wire [CYC_W-1:0]         cycle_count;

    // Controller outputs that stay inside the accelerator.
    wire              array_clear;
    wire              array_en;
    wire              capture;
    wire [STEP_W-1:0] step;
    // k_len of the current run, held by the controller, to both skew buffers.
    wire [K_LEN_W-1:0] run_k_len;

    // Datapath between the blocks.
    wire [N*DATA_W-1:0]  a_left;
    wire [N*DATA_W-1:0]  b_top;
    wire [N*N*ACC_W-1:0] acc_flat;

    // Phase 1 behaviour until #62: K_MAX = K = N, every run has k_len = N and no
    // accumulate (spec section 14).
    sa_controller #(
        .N    (N),
        .K_MAX(K),
        .CYC_W(CYC_W)
    ) u_controller (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .k_len      (K[K_LEN_W-1:0]),
        .accumulate (1'b0),
        .busy       (busy),
        .done       (done),
        .clear      (array_clear),
        .en         (array_en),
        .step       (step),
        .run_k_len  (run_k_len),
        .capture    (capture),
        .cycle_count(cycle_count)
    );

    // Phase 1 behaviour until #62: K_MAX = K = N (spec section 14).
    input_skew_buffer #(
        .N           (N),
        .K_MAX       (K),
        .DATA_W      (DATA_W),
        .COLUMN_LANES(0)
    ) u_a_buffer (
        .clk  (clk),
        .rst_n(rst_n),
        .we   (a_we && !busy),
        .waddr(a_addr),
        .wdata(a_wdata),
        .en   (array_en),
        .step (step),
        .k_len(run_k_len),
        .lanes(a_left)
    );

    input_skew_buffer #(
        .N           (N),
        .K_MAX       (K),
        .DATA_W      (DATA_W),
        .COLUMN_LANES(1)
    ) u_b_buffer (
        .clk  (clk),
        .rst_n(rst_n),
        .we   (b_we && !busy),
        .waddr(b_addr),
        .wdata(b_wdata),
        .en   (array_en),
        .step (step),
        .k_len(run_k_len),
        .lanes(b_top)
    );

    systolic_array #(
        .N     (N),
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) u_array (
        .clk     (clk),
        .rst_n   (rst_n),
        .clear   (array_clear),
        .en      (array_en),
        .a_left  (a_left),
        .b_top   (b_top),
        .acc_flat(acc_flat)
    );

    output_buffer #(
        .N    (N),
        .ACC_W(ACC_W)
    ) u_output_buffer (
        .clk     (clk),
        .rst_n   (rst_n),
        .capture (capture),
        .acc_flat(acc_flat),
        .c_addr  (c_addr),
        .c_rdata (c_rdata)
    );

endmodule

`default_nettype wire
