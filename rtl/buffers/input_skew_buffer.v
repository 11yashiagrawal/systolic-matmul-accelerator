`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Operand storage and skewed edge feed (docs/spec.md section 6.4, issue #10).
//
// Stores one N x N matrix M, written row-major through we/waddr/wdata. While en is
// high, lane l in compute step t carries
//   COLUMN_LANES = 0 (A, lane l is row l):    M[l][t - l]
//   COLUMN_LANES = 1 (B, lane l is column l): M[t - l][l]
// and zero outside 0 <= t - l < K, so lane l reaches the array l cycles late.
module input_skew_buffer (
    clk,
    rst_n,
    we,
    waddr,
    wdata,
    en,
    step,
    lanes
);

    parameter N            = `SA_N;
    parameter DATA_W       = `SA_DATA_W;
    parameter COLUMN_LANES = 0;

    localparam K      = N;
    localparam T      = K + 2*N - 2;
    localparam ADDR_W = $clog2(N*N);
    localparam STEP_W = $clog2(T);

    input  wire                     clk;
    input  wire                     rst_n;
    input  wire                     we;
    input  wire [ADDR_W-1:0]        waddr;
    input  wire signed [DATA_W-1:0] wdata;
    input  wire                     en;
    input  wire [STEP_W-1:0]        step;
    output reg  [N*DATA_W-1:0]      lanes;

    // Element (r, c) lives at [(r*N + c)*DATA_W +: DATA_W].
    reg [N*N*DATA_W-1:0] mem;

    // Addresses N*N and above (possible when N*N is not a power of two) are ignored.
    wire addr_ok = ({{(32-ADDR_W){1'b0}}, waddr} < N*N);

    always @(posedge clk) begin
        if (!rst_n)
            mem <= {(N*N*DATA_W){1'b0}};
        else if (we && addr_ok)
            mem[waddr*DATA_W +: DATA_W] <= wdata;
    end

    // t >= l is checked before subtracting, so the index never wraps (spec 6.4).
    integer t;
    integer l;
    integer k;
    always @(*) begin
        lanes = {(N*DATA_W){1'b0}};
        t     = {{(32-STEP_W){1'b0}}, step};
        k     = 0;
        if (en) begin
            for (l = 0; l < N; l = l + 1) begin
                if (t >= l && t - l < K) begin
                    k = t - l;
                    if (COLUMN_LANES == 0)
                        lanes[l*DATA_W +: DATA_W] = mem[(l*N + k)*DATA_W +: DATA_W];
                    else
                        lanes[l*DATA_W +: DATA_W] = mem[(k*N + l)*DATA_W +: DATA_W];
                end
            end
        end
    end

endmodule

`default_nettype wire
