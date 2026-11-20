`timescale 1ns / 1ps
`default_nettype none
`include "sa_params.vh"

// Sequencer for one matrix multiplication (docs/spec.md sections 6.6 and 7.3-7.5,
// issues #7 and #65).
//
//   start, accumulate low:  IDLE/DONE -> CLEAR -> COMPUTE (T steps) -> CAPTURE -> DONE
//   start, accumulate high: IDLE/DONE ---------> COMPUTE (T steps) -> CAPTURE -> DONE
//
// T = k_len + 2N - 2, where k_len (1 to K_MAX) is the inner length of this run.
// k_len and accumulate are sampled together with start and held for the whole
// run; run_k_len is the held value, for the skew buffers. A start whose k_len is
// 0 or above K_MAX is ignored. An accumulate run skips CLEAR, so the array adds
// this run onto the accumulators of the previous one.
//
// start is sampled in IDLE and DONE only. busy, done, clear, en and capture are
// decoded from the state register, so they change only at clock edges.
module sa_controller (
    clk,
    rst_n,
    start,
    k_len,
    accumulate,
    busy,
    done,
    clear,
    en,
    step,
    run_k_len,
    capture,
    cycle_count
);

    parameter N     = `SA_N;
    parameter K_MAX = `SA_K_MAX;
    parameter CYC_W = `SA_CYC_W;

    localparam T_MAX   = K_MAX + 2*N - 2;     // longest run (22 for N = 4, K_MAX = 16)
    localparam STEP_W  = $clog2(T_MAX);
    localparam K_LEN_W = $clog2(K_MAX + 1);   // holds 0 to K_MAX

    input  wire                 clk;
    input  wire                 rst_n;
    input  wire                 start;
    input  wire [K_LEN_W-1:0]   k_len;
    input  wire                 accumulate;
    output wire                 busy;
    output wire                 done;
    output wire                 clear;
    output wire                 en;
    output reg  [STEP_W-1:0]    step;
    output reg  [K_LEN_W-1:0]   run_k_len;
    output wire                 capture;
    output reg  [CYC_W-1:0]     cycle_count;

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

    // Zero-extend to 32 bits so every compare with a 32-bit constant is
    // width-clean for every N and K_MAX.
    wire [31:0] k_len_32     = {{(32-K_LEN_W){1'b0}}, k_len};
    wire [31:0] run_k_len_32 = {{(32-K_LEN_W){1'b0}}, run_k_len};
    wire [31:0] step_32      = {{(32-STEP_W){1'b0}}, step};

    wire k_len_ok = (k_len_32 >= 32'd1) && (k_len_32 <= K_MAX);
    wire go       = start && k_len_ok;

    // The last compute step of this run is T - 1 = run_k_len + 2N - 3.
    wire last_step = (step_32 + 32'd3 == run_k_len_32 + 2*N);

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            step        <= {STEP_W{1'b0}};
            run_k_len   <= {K_LEN_W{1'b0}};
            cycle_count <= {CYC_W{1'b0}};
        end else begin
            case (state)
                S_IDLE, S_DONE: begin
                    step <= {STEP_W{1'b0}};
                    if (go) begin
                        state       <= accumulate ? S_COMPUTE : S_CLEAR;
                        run_k_len   <= k_len;
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
                    if (last_step) begin
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

                default: begin
                    state <= S_IDLE;
                    step  <= {STEP_W{1'b0}};
                end
            endcase
        end
    end

endmodule

`default_nettype wire
