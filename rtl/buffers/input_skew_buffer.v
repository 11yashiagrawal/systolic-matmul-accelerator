`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Operand storage and skewed edge feed (docs/spec.md section 6.4, issues #10 and #68).
//
// Stores one operand matrix M, written through we/waddr/wdata:
//   COLUMN_LANES = 0 (A, N x K_MAX):  M[r][k] at address r*K_MAX + k
//   COLUMN_LANES = 1 (B, K_MAX x N):  M[k][c] at address k*N + c
// With K_MAX = N both are the Phase 1 row-major map (spec section 8).
//
// k_len is the inner length of the current run (1 to K_MAX), the controller's
// run_k_len. While en is high, lane l in compute step t carries
//   COLUMN_LANES = 0 (lane l is row l):    M[l][t - l]
//   COLUMN_LANES = 1 (lane l is column l): M[t - l][l]
// and zero outside 0 <= t - l < k_len, so lane l reaches the array l cycles late
// and elements past k_len never enter it, whatever they hold.
module input_skew_buffer (
    clk,
    rst_n,
    we,
    waddr,
    wdata,
    en,
    step,
    k_len,
    lanes
);

    parameter N            = `SA_N;
    parameter K_MAX        = `SA_K_MAX;
    parameter DATA_W       = `SA_DATA_W;
    parameter COLUMN_LANES = 0;

    localparam DEPTH     = N * K_MAX;               // elements stored
    localparam T_MAX     = K_MAX + 2*N - 2;
    localparam OP_ADDR_W = $clog2(DEPTH);
    localparam STEP_W    = $clog2(T_MAX);
    localparam K_LEN_W   = $clog2(K_MAX + 1);       // holds 0 to K_MAX

    input  wire                     clk;
    input  wire                     rst_n;
    input  wire                     we;
    input  wire [OP_ADDR_W-1:0]     waddr;
    input  wire signed [DATA_W-1:0] wdata;
    input  wire                     en;
    input  wire [STEP_W-1:0]        step;
    input  wire [K_LEN_W-1:0]       k_len;
    output reg  [N*DATA_W-1:0]      lanes;

    // Element at address a lives at [a*DATA_W +: DATA_W].
    reg [DEPTH*DATA_W-1:0] mem;

    // Addresses DEPTH and above (possible when DEPTH is not a power of two) are ignored.
    wire addr_ok = ({{(32-OP_ADDR_W){1'b0}}, waddr} < DEPTH);

    always @(posedge clk) begin
        if (!rst_n)
            mem <= {(DEPTH*DATA_W){1'b0}};
        else if (we && addr_ok)
            mem[waddr*DATA_W +: DATA_W] <= wdata;
    end

    // t >= l is checked before subtracting, so the index never wraps (spec 6.4).
    // k < K_MAX also holds whenever k < k_len <= K_MAX; it is checked anyway so an
    // out-of-range k_len can never read past the storage.
    integer t;
    integer l;
    integer k;
    integer kl;
    always @(*) begin
        lanes = {(N*DATA_W){1'b0}};
        t     = {{(32-STEP_W){1'b0}}, step};
        kl    = {{(32-K_LEN_W){1'b0}}, k_len};
        k     = 0;
        if (en) begin
            for (l = 0; l < N; l = l + 1) begin
                if (t >= l && t - l < kl && t - l < K_MAX) begin
                    k = t - l;
                    if (COLUMN_LANES == 0)
                        lanes[l*DATA_W +: DATA_W] = mem[(l*K_MAX + k)*DATA_W +: DATA_W];
                    else
                        lanes[l*DATA_W +: DATA_W] = mem[(k*N + l)*DATA_W +: DATA_W];
                end
            end
        end
    end

endmodule

`default_nettype wire
