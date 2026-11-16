`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Sequencer for one matrix multiplication (docs/spec.md sections 6.6 and 7.3-7.5, issue #7).
//
// IDLE -> CLEAR -> COMPUTE (T = K + 2N - 2 steps) -> CAPTURE -> DONE
// start is sampled in IDLE and DONE only. busy, done, clear, en and capture are
// decoded from the state register, so they change only at clock edges.
module sa_controller (
    clk,
    rst_n,
    start,
    busy,
    done,
    clear,
    en,
    step,
    capture,
    cycle_count
);

    parameter N     = `SA_N;
    parameter CYC_W = `SA_CYC_W;

    localparam K      = N;
    localparam T      = K + 2*N - 2;   // compute cycles (10 for N = 4)
    localparam STEP_W = $clog2(T);

    input  wire                clk;
    input  wire                rst_n;
    input  wire                start;
    output wire                busy;
    output wire                done;
    output wire                clear;
    output wire                en;
    output reg  [STEP_W-1:0]   step;
    output wire                capture;
    output reg  [CYC_W-1:0]    cycle_count;

    localparam [2:0] S_IDLE    = 3'd0,
                     S_CLEAR   = 3'd1,
                     S_COMPUTE = 3'd2,
                     S_CAPTURE = 3'd3,
                     S_DONE    = 3'd4;

    reg [2:0] state;

    assign busy    = (state == S_CLEAR) || (state == S_COMPUTE) || (state == S_CAPTURE);
    assign done    = (state == S_DONE);
    assign clear   = (state == S_CLEAR);
    assign en      = (state == S_COMPUTE);
    assign capture = (state == S_CAPTURE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            step        <= {STEP_W{1'b0}};
            cycle_count <= {CYC_W{1'b0}};
        end else begin
            case (state)
                S_IDLE: begin
                    step <= {STEP_W{1'b0}};
                    if (start) begin
                        state       <= S_CLEAR;
                        cycle_count <= {CYC_W{1'b0}};
                    end
                end

                S_CLEAR: begin
                    state       <= S_COMPUTE;
                    step        <= {STEP_W{1'b0}};
                    cycle_count <= cycle_count + 1'b1;
                end

                S_COMPUTE: begin
                    cycle_count <= cycle_count + 1'b1;
                    // Zero-extend step to 32 bits so the compare with the
                    // 32-bit constant is width-clean for every N.
                    if ({{(32-STEP_W){1'b0}}, step} == T - 1) begin
                        state <= S_CAPTURE;
                        step  <= {STEP_W{1'b0}};
                    end else begin
                        step <= step + 1'b1;
                    end
                end

                S_CAPTURE: begin
                    state       <= S_DONE;
                    step        <= {STEP_W{1'b0}};
                    cycle_count <= cycle_count + 1'b1;
                end

                S_DONE: begin
                    step <= {STEP_W{1'b0}};
                    if (start) begin
                        state       <= S_CLEAR;
                        cycle_count <= {CYC_W{1'b0}};
                    end
                end

                default: begin
                    state <= S_IDLE;
                    step  <= {STEP_W{1'b0}};
                end
            endcase
        end
    end

endmodule

`default_nettype wire
