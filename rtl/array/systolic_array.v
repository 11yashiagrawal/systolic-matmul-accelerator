// N x N output-stationary systolic array (issue #3).
// Contract: docs/spec.md sections 6.3 and 7.
//
// PE (i, j) keeps C[i][j] in its accumulator. Operands enter on the left edge
// (row i of A on lane i of a_left) and the top edge (column j of B on lane j of
// b_top), already skewed by input_skew_buffer. Each PE passes its A operand one
// PE to the right and its B operand one PE down every enabled cycle.

`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

module systolic_array #(
    parameter N      = `SA_N,
    parameter DATA_W = `SA_DATA_W,
    parameter ACC_W  = `SA_ACC_W
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 clear,     // to every PE: zero accumulators and forwarding registers
    input  wire                 en,        // to every PE: accumulate and forward this cycle
    input  wire [N*DATA_W-1:0]  a_left,    // lane i -> a_in of PE (i, 0)
    input  wire [N*DATA_W-1:0]  b_top,     // lane j -> b_in of PE (0, j)
    output wire [N*N*ACC_W-1:0] acc_flat   // acc of PE (i, j) at [(i*N+j)*ACC_W +: ACC_W]
);

    // Horizontal links. Slot (i, j) of a_link is the operand entering PE (i, j)
    // from the left; there are N+1 slots per row, and slot (i, N) is the a_out of
    // the last column, which leaves the array.
    //
    // Vertical links. Slot (i, j) of b_link is the operand entering PE (i, j)
    // from above; there are N+1 rows of slots, and row N holds the b_out of the
    // last row, which leaves the array.
    //
    // The two exit edges are unused by design (docs/spec.md section 6.3).
    /* verilator lint_off UNUSEDSIGNAL */
    wire [N*(N+1)*DATA_W-1:0] a_link;
    wire [(N+1)*N*DATA_W-1:0] b_link;
    /* verilator lint_on UNUSEDSIGNAL */

    genvar i, j;
    generate
        // Edge inputs.
        for (i = 0; i < N; i = i + 1) begin : g_left_edge
            assign a_link[(i*(N+1))*DATA_W +: DATA_W] = a_left[i*DATA_W +: DATA_W];
        end
        for (j = 0; j < N; j = j + 1) begin : g_top_edge
            assign b_link[j*DATA_W +: DATA_W] = b_top[j*DATA_W +: DATA_W];
        end

        // The grid.
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (j = 0; j < N; j = j + 1) begin : g_col
                pe #(
                    .DATA_W(DATA_W),
                    .ACC_W (ACC_W)
                ) u_pe (
                    .clk  (clk),
                    .rst_n(rst_n),
                    .clear(clear),
                    .en   (en),
                    .a_in (a_link[(i*(N+1)+j)*DATA_W +: DATA_W]),
                    .b_in (b_link[(i*N+j)*DATA_W +: DATA_W]),
                    .a_out(a_link[(i*(N+1)+j+1)*DATA_W +: DATA_W]),
                    .b_out(b_link[((i+1)*N+j)*DATA_W +: DATA_W]),
                    .acc  (acc_flat[(i*N+j)*ACC_W +: ACC_W])
                );
            end
        end
    endgenerate

endmodule

`default_nettype wire
