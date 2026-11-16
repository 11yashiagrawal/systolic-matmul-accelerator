`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Signed multiply-accumulate unit (docs/spec.md section 6.1, issue #6).
//
// Each enabled cycle adds the sign-extended product a * b to acc.
// clear has priority over en, and reset behaves like clear.
module mac #(
    parameter DATA_W = `SA_DATA_W,
    parameter ACC_W  = `SA_ACC_W
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     clear,
    input  wire                     en,
    input  wire signed [DATA_W-1:0] a,
    input  wire signed [DATA_W-1:0] b,
    output reg  signed [ACC_W-1:0]  acc
);

    // Natural-width product, then sign-extended to ACC_W (spec section 4).
    wire signed [2*DATA_W-1:0] prod = a * b;

    always @(posedge clk) begin
        if (!rst_n || clear)
            acc <= {ACC_W{1'b0}};
        else if (en)
            acc <= acc + {{(ACC_W - 2*DATA_W){prod[2*DATA_W-1]}}, prod};
    end

endmodule

`default_nettype wire
