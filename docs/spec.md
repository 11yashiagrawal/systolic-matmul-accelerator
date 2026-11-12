# Architecture spec and interface contract

This document is the contract every module is built and tested against (issue #2). Port names, widths, timing and the handshake defined here are fixed. To change any of them, open a PR against this file first and tag the owners of the affected modules.

## 1. What the accelerator does

It computes **C = A × B** for signed fixed-point matrices, with A and B both N×N and N = 4 by default:

```
C[i][j] = sum over k = 0 .. K-1 of  A[i][k] * B[k][j]
```

In Phase 1 the inner dimension K equals N. The formulas below keep K separate so they still hold when Phase 2 relaxes that.

A host (the testbench in Phase 1) loads A and B through two write ports, pulses `start`, waits for `done`, and reads C through a read port.

## 2. Dataflow: output-stationary

The array is an N×N grid of processing elements (PEs). PE (i, j) owns `C[i][j]` and keeps it in its accumulator for the whole computation. Only the operands move:

- **A moves right.** Row i of A enters PE (i, 0) from the left edge and is passed one PE to the right every cycle.
- **B moves down.** Column j of B enters PE (0, j) from the top edge and is passed one PE down every cycle.
- **Inputs are skewed.** Row i of A starts i cycles late, and column j of B starts j cycles late. Then `A[i][k]` and `B[k][j]` reach PE (i, j) in the same cycle, and the PE multiplies them and adds the product to `C[i][j]`.

```
               b_top[0]  b_top[1]  b_top[2]  b_top[3]      B enters here,
                  |         |         |         |          column j skewed by j
                  v         v         v         v
a_left[0] --> PE(0,0) -> PE(0,1) -> PE(0,2) -> PE(0,3)
                  |         |         |         |
a_left[1] --> PE(1,0) -> PE(1,1) -> PE(1,2) -> PE(1,3)
                  |         |         |         |
a_left[2] --> PE(2,0) -> PE(2,1) -> PE(2,2) -> PE(2,3)
                  |         |         |         |
a_left[3] --> PE(3,0) -> PE(3,1) -> PE(3,2) -> PE(3,3)

A enters here, row i skewed by i.   Each PE keeps C[i][j] in place.
```

Output-stationary was chosen because each result stays in one place, so reading C out needs no extra movement, and every step of the computation is easy to see in a waveform. Weight-stationary and other dataflows are discussed in the literature review (#15).

## 3. Parameters

Defaults live in [`rtl/include/sa_params.vh`](../rtl/include/sa_params.vh). Each module declares the parameters it uses with those defaults and computes the derived widths itself.

| Parameter | Default | Meaning |
|---|---|---|
| `N` | 4 | Array is N×N PEs; matrices are N×N |
| `DATA_W` | 8 | Operand width, signed two's complement |
| `ACC_W` | 32 | Accumulator and result width, signed two's complement |
| `FRAC_W` | 0 | Fractional bits in the fixed-point reading of operands (interpretation only) |
| `CYC_W` | 32 | Width of `cycle_count` |

| Derived (localparam) | Formula | N = 4 |
|---|---|---|
| `K` | `N` | 4 |
| `T` (compute cycles) | `K + 2*N - 2` | 10 |
| `ADDR_W` | `$clog2(N*N)` | 4 |
| `STEP_W` | `$clog2(K + 2*N - 2)` | 4 |

## 4. Number format

- **Operands** are `DATA_W`-bit signed integers, from −128 to 127 for the default.
- **Products** are `2*DATA_W` bits wide and are sign-extended to `ACC_W` before they are added.
- **Accumulators** are `ACC_W`-bit signed. The largest possible magnitude is `K * 2^(2*DATA_W - 2)`, reached when every operand is −128: for K = 4 that is 65,536, which needs 18 bits. With `ACC_W = 32`, overflow cannot happen for any K below 131,072, so the RTL does not saturate.
- **Fixed-point reading.** With `FRAC_W = f`, an operand's bit pattern `x` means `x / 2^f` (format Q(`DATA_W` − 1 − f).f). A result `C` then has `2f` fractional bits and means `C / 2^(2f)`. To return it to the operands' format, shift it right arithmetically by f. Phase 1 reads every result at full precision, so f = 0 and the reference model compares plain integers. Rounding and saturating back to `DATA_W` bits is Phase 2 work.

### Signed arithmetic pitfalls

Verilog makes an expression unsigned as soon as one operand is unsigned, and then it zero-extends. Two rules prevent this:

1. Wrap every slice of a flattened bus in `$signed(...)` before using it in arithmetic. Slices are always unsigned.
2. Form the product at its natural width, then sign-extend it explicitly:

```verilog
wire signed [2*DATA_W-1:0] prod = a * b;   // a and b declared signed
acc <= acc + {{(ACC_W-2*DATA_W){prod[2*DATA_W-1]}}, prod};
```

## 5. Conventions for every module

- Synthesizable Verilog-2005. Each file starts with `` `default_nettype none `` and ends with `` `default_nettype wire ``.
- One clock, `clk`; every register updates on its rising edge.
- Reset is **synchronous and active-low**: `rst_n = 0` at a rising edge puts every register in this design into its reset value (zero, or `IDLE` for the controller).
- Ports that carry one value are declared `signed`. Ports that carry several values are flattened, unsigned buses with lane `l` at `[l*W +: W]`.
- Combinational outputs are named in this spec. Every other output comes straight from a register.
