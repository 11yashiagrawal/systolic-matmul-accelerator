`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Processing element (docs/spec.md section 6.2, issue #6).
//
// Holds C[i][j] in acc. In each enabled cycle it accumulates a_in * b_in and
// forwards a_in to the right (a_out) and b_in down (b_out), one cycle later.
module pe #(
    parameter DATA_W = `SA_DATA_W,
    parameter ACC_W  = `SA_ACC_W
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,
    input  wire                     en,
    input  wire signed [DATA_W-1:0] a_in,
    input  wire signed [DATA_W-1:0] b_in,
    output reg  signed [DATA_W-1:0] a_out,
    output reg  signed [DATA_W-1:0] b_out,
    output wire signed [ACC_W-1:0]  acc
);

    mac #(
        .DATA_W(DATA_W),
        .ACC_W (ACC_W)
    ) u_mac (
        .clk  (clk),
        .rst_n(rst_n),
        .clear(clear),
        .en   (en),
        .a    (a_in),
        .b    (b_in),
        .acc  (acc)
    );

    always @(posedge clk) begin
        if (!rst_n || clear) begin
            a_out <= {DATA_W{1'b0}};
            b_out <= {DATA_W{1'b0}};
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
        end
    end

endmodule

`default_nettype wire
