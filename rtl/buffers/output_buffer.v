`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Result capture and read port (docs/spec.md section 6.5, issue #10).
//
// On a rising edge with capture high, all N x N result registers load acc_flat at
// once. They hold until the next capture, so the previous C stays readable while
// the next multiplication runs. c_rdata is the result at row-major address c_addr.
module output_buffer (
    clk,
    rst_n,
    capture,
    acc_flat,
    c_addr,
    c_rdata
);

    parameter N     = `SA_N;
    parameter ACC_W = `SA_ACC_W;

    localparam ADDR_W = $clog2(N*N);

    input  wire                    clk;
    input  wire                    rst_n;
    input  wire                    capture;
    input  wire [N*N*ACC_W-1:0]    acc_flat;
    input  wire [ADDR_W-1:0]       c_addr;
    output wire signed [ACC_W-1:0] c_rdata;

    // C[r][c] lives at [(r*N + c)*ACC_W +: ACC_W], the same order as acc_flat.
    reg [N*N*ACC_W-1:0] results;

    always @(posedge clk) begin
        if (!rst_n)
            results <= {(N*N*ACC_W){1'b0}};
        else if (capture)
            results <= acc_flat;
    end

    // Addresses N*N and above (possible when N*N is not a power of two) read 0.
    wire addr_ok = ({{(32-ADDR_W){1'b0}}, c_addr} < N*N);

    assign c_rdata = addr_ok ? results[c_addr*ACC_W +: ACC_W] : {ACC_W{1'b0}};

endmodule

`default_nettype wire
