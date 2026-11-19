// Default parameters for the systolic-array accelerator (issue #2).
// Every module takes these as parameter defaults, for example:
//
//   `include "sa_params.vh"
//   module pe #(parameter DATA_W = `SA_DATA_W, parameter ACC_W = `SA_ACC_W) (...);
//
// Derived widths are computed inside each module from its own parameters, never
// copied from here, so a parent can override N, DATA_W or ACC_W in one place.
// The timing and interface contract these values belong to is docs/spec.md.

`ifndef SA_PARAMS_VH
`define SA_PARAMS_VH

// Array is N x N processing elements; C is computed in N x N tiles.
`define SA_N        4

// Largest inner length of one run (Phase 2, issue #60). A run multiplies an
// N x k_len block of A by a k_len x N block of B, with 1 <= k_len <= K_MAX, and
// longer products run as chunks with accumulate starts (docs/spec.md section 12).
// K_MAX = N gives the Phase 1 address map.
`define SA_K_MAX    16

// Operand width: signed two's complement.
`define SA_DATA_W   8

// Accumulator width: signed two's complement. Needs at least 2*DATA_W + clog2(K)
// bits for a total inner dimension K across all chunks (18 bits for K = 4);
// 32 bits holds any K below 131,072.
`define SA_ACC_W    32

// Fractional bits of the fixed-point (Q) reading of operands. Interpretation
// only: the hardware is pure integer, so this never changes the RTL.
`define SA_FRAC_W   0

// Width of the cycle_count output.
`define SA_CYC_W    32

`endif // SA_PARAMS_VH
