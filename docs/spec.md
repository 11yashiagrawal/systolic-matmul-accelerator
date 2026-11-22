# Architecture spec and interface contract

This document is the contract every module is built and tested against (issue #2). Version 2 (issue #60) adds a run-time inner length, accumulate runs, tiling of larger products, the sequential baseline and the synthesis targets for Phase 2. Port names, widths, timing and the handshake defined here are fixed. To change any of them, open a PR against this file first and tag the owners of the affected modules.

## 1. What the accelerator does

One run computes **C = A × B** for signed fixed-point matrices, with A of size N×`k_len` and B of size `k_len`×N. N is 4 by default, and the inner length `k_len` is chosen for each run, from 1 to `K_MAX` (16 by default):

```
C[i][j] = sum over k = 0 .. k_len-1 of  A[i][k] * B[k][j]
```

An **accumulate** run adds its products onto the C of the previous run instead of starting from zero. With it, a host can multiply matrices of any size: it splits C into N×N tiles and the inner dimension into chunks of at most `K_MAX`, and runs one chunk at a time (section 12). Phase 1 fixed `k_len` at N; that case behaves exactly as before.

A host (a testbench or the demo) loads A and B through two write ports, sets `k_len` and `accumulate`, pulses `start`, waits for `done`, and reads C through a read port. The sequential baseline `seq_matmul` (6.8) has the same ports, so the same host drives both designs.

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
| `N` | 4 | Array is N×N PEs; C is computed in N×N tiles. N ≥ 2 |
| `K_MAX` | 16 | Largest inner length of one run; A is stored as N×`K_MAX` and B as `K_MAX`×N. `K_MAX` ≥ N |
| `DATA_W` | 8 | Operand width, signed two's complement |
| `ACC_W` | 32 | Accumulator and result width, signed two's complement |
| `FRAC_W` | 0 | Fractional bits in the fixed-point reading of operands (interpretation only) |
| `CYC_W` | 32 | Width of `cycle_count` |

| Derived (localparam) | Formula | N = 4, `K_MAX` = 16 | Phase 1 (`K_MAX` = N = 4) |
|---|---|---|---|
| `T_MAX` (compute cycles of the longest run) | `K_MAX + 2*N - 2` | 22 | 10 |
| `STEP_W` | `$clog2(T_MAX)` | 5 | 4 |
| `K_LEN_W` | `$clog2(K_MAX + 1)` | 5 | 3 |
| `OP_ADDR_W` (A and B ports) | `$clog2(N*K_MAX)` | 6 | 4 |
| `ADDR_W` (C port) | `$clog2(N*N)` | 4 | 4 |

The compute length of a run, `T = k_len + 2N − 2`, is no longer a parameter: the controller computes it from the `k_len` it samples at `start` (section 7). With `K_MAX` = N, `k_len` = N and `accumulate` low, every address and cycle count is the Phase 1 one.

## 4. Number format

- **Operands** are `DATA_W`-bit signed integers, from −128 to 127 for the default.
- **Products** are `2*DATA_W` bits wide and are sign-extended to `ACC_W` before they are added.
- **Accumulators** are `ACC_W`-bit signed. The largest possible magnitude is `K * 2^(2*DATA_W - 2)`, reached when every operand is −128, where K is the whole inner dimension of the product, across all its chunks: for K = 4 that is 65,536, which needs 18 bits. With `ACC_W = 32`, overflow cannot happen for any K below 131,072, so the RTL does not saturate.
- **Fixed-point reading.** With `FRAC_W = f`, an operand's bit pattern `x` means `x / 2^f` (format Q(`DATA_W` − 1 − f).f). A result `C` then has `2f` fractional bits and means `C / 2^(2f)`. To return it to the operands' format, shift it right arithmetically by f. Phase 1 reads every result at full precision, so f = 0 and the reference model compares plain integers. Rounding and saturating back to `DATA_W` bits is out of scope (section 15).

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
- Every file, RTL and testbench alike, declares `` `timescale 1ns / 1ps `` on its first code line. If only some files declare it, Icarus warns that the others inherit it, and waveforms are easier to read in nanoseconds than in the default seconds. Testbenches use a 10 ns clock period.
- One clock, `clk`; every register updates on its rising edge.
- Reset is **synchronous and active-low**: `rst_n = 0` at a rising edge puts every register in this design into its reset value (zero, or `IDLE` for the controller).
- Ports that carry one value are declared `signed`. Ports that carry several values are flattened, unsigned buses with lane `l` at `[l*W +: W]`.
- Combinational outputs are named in this spec. Every other output comes straight from a register.

## 6. Modules and ports

`W` columns give the width in bits. `s` marks a signed port. "Reg" means the output comes straight from a register; "comb" means it is combinational.

```mermaid
flowchart LR
  host([Host or testbench])
  subgraph top [systolic_top]
    abuf["input_skew_buffer (A)<br/>COLUMN_LANES = 0"]
    bbuf["input_skew_buffer (B)<br/>COLUMN_LANES = 1"]
    arr["systolic_array<br/>N x N pe"]
    obuf[output_buffer]
    ctrl[sa_controller]
  end
  host -- "a_we, a_addr, a_wdata" --> abuf
  host -- "b_we, b_addr, b_wdata" --> bbuf
  host -- "start, k_len, accumulate" --> ctrl
  ctrl -- "busy, done, cycle_count" --> host
  abuf -- a_left --> arr
  bbuf -- b_top --> arr
  ctrl -- "en, step, run_k_len" --> abuf
  ctrl -- "en, step, run_k_len" --> bbuf
  ctrl -- "clear, en" --> arr
  arr -- acc_flat --> obuf
  ctrl -- capture --> obuf
  host -- c_addr --> obuf
  obuf -- c_rdata --> host
```

### 6.1 `mac` — `rtl/pe/mac.v` (#6)

Parameters: `DATA_W`, `ACC_W`.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset |
| `clear` | in | 1 | Zero the accumulator |
| `en` | in | 1 | Accumulate this cycle |
| `a`, `b` | in | `DATA_W` s | Operands |
| `acc` | out (reg) | `ACC_W` s | Running sum |

At each rising edge, in priority order: `!rst_n` or `clear` sets `acc <= 0`; otherwise `en` sets `acc <= acc + a*b` (sign-extended product, section 4); otherwise `acc` holds.

### 6.2 `pe` — `rtl/pe/pe.v` (#6)

Parameters: `DATA_W`, `ACC_W`. Contains one `mac` and two forwarding registers.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset |
| `clear` | in | 1 | Zero the accumulator and both forwarding registers |
| `en` | in | 1 | Accumulate and forward this cycle |
| `a_in` | in | `DATA_W` s | Operand from the left neighbour (or the A edge) |
| `b_in` | in | `DATA_W` s | Operand from the neighbour above (or the B edge) |
| `a_out` | out (reg) | `DATA_W` s | `a_in` delayed one enabled cycle, to the right neighbour |
| `b_out` | out (reg) | `DATA_W` s | `b_in` delayed one enabled cycle, to the neighbour below |
| `acc` | out (reg) | `ACC_W` s | The `mac` accumulator, `C[i][j]` |

At each rising edge: `!rst_n` or `clear` zeroes `a_out`, `b_out` and `acc`; otherwise, when `en` is high, `a_out <= a_in`, `b_out <= b_in` and `acc <= acc + a_in*b_in`; otherwise all three hold. So an operand that enters a PE in one enabled cycle leaves it in the next.

### 6.3 `systolic_array` — `rtl/array/systolic_array.v` (#3)

Parameters: `N`, `DATA_W`, `ACC_W`. Instantiates N×N `pe` with `generate` loops.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset |
| `clear`, `en` | in | 1 | Broadcast to every PE |
| `a_left` | in | `N*DATA_W` | Lane i drives `a_in` of PE (i, 0) |
| `b_top` | in | `N*DATA_W` | Lane j drives `b_in` of PE (0, j) |
| `acc_flat` | out (reg) | `N*N*ACC_W` | `acc` of PE (i, j) at `[(i*N+j)*ACC_W +: ACC_W]` |

Inside: `a_in` of PE (i, j) is `a_out` of PE (i, j−1), and `b_in` of PE (i, j) is `b_out` of PE (i−1, j). The `a_out` of the last column and the `b_out` of the last row are unused; waive that lint warning with a comment.

### 6.4 `input_skew_buffer` — `rtl/buffers/input_skew_buffer.v` (#10)

Parameters: `N`, `K_MAX`, `DATA_W`, `COLUMN_LANES`. It stores one operand block and feeds it into one edge of the array with the skew. The top level instantiates it twice:

- `COLUMN_LANES = 0` for A: N rows of `K_MAX` elements, and lane l is row l.
- `COLUMN_LANES = 1` for B: `K_MAX` rows of N elements, and lane l is column l.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (storage resets to 0) |
| `we` | in | 1 | Write `wdata` at `waddr` this cycle |
| `waddr` | in | `OP_ADDR_W` | Element address (section 8): `A[r][k]` at `r*K_MAX + k`, `B[k][c]` at `k*N + c` |
| `wdata` | in | `DATA_W` s | Element value |
| `en` | in | 1 | Feeding is active (the controller's COMPUTE state) |
| `step` | in | `STEP_W` | Compute step `t`, from 0 to `T − 1` |
| `k_len` | in | `K_LEN_W` | Inner length of the current run, from the controller's `run_k_len` |
| `lanes` | out (comb) | `N*DATA_W` | Lane l at `[l*DATA_W +: DATA_W]` |

Storage `M` is written at the rising edge when `we` is high: `M[waddr / K_MAX][waddr % K_MAX] <= wdata` for A, and `M[waddr / N][waddr % N] <= wdata` for B. Writes at or above `N*K_MAX` are ignored. Each lane `l` is combinational in `step`, `k_len` and `M`:

| Condition | `COLUMN_LANES = 0` (A) | `COLUMN_LANES = 1` (B) |
|---|---|---|
| `en` high and `0 <= t − l < k_len` | `M[l][t − l]` | `M[t − l][l]` |
| otherwise | 0 | 0 |

Elements with k ≥ `k_len` may hold old data or filler from an earlier run. The `k_len` bound keeps them out of the array, so the host never has to clear them. Compare `t >= l` before subtracting: `t − l` on unsigned values wraps around. An implementation built from shift registers is also fine, as long as the lanes match this table in every cycle.

### 6.5 `output_buffer` — `rtl/buffers/output_buffer.v` (#10)

Parameters: `N`, `ACC_W`.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (results reset to 0) |
| `capture` | in | 1 | Copy every accumulator into the result registers this cycle |
| `acc_flat` | in | `N*N*ACC_W` | From `systolic_array` |
| `c_addr` | in | `ADDR_W` | Row-major address of the result to read |
| `c_rdata` | out (comb) | `ACC_W` s | Result register at `c_addr` |

At the rising edge with `capture` high, all N×N result registers load `acc_flat` at once. They hold until the next capture, so the previous C stays readable while the next multiplication runs. An accumulate run captures the same way; the accumulators then hold the sum over every chunk so far.

### 6.6 `sa_controller` — `rtl/control/sa_controller.v` (#7)

Parameters: `N`, `K_MAX`, `CYC_W`. Behaviour and timing are in section 7.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (to `IDLE`) |
| `start` | in | 1 | Begin a run; sampled in `IDLE` and `DONE` only, and accepted only when 1 ≤ `k_len` ≤ `K_MAX` |
| `k_len` | in | `K_LEN_W` | Inner length of the next run; sampled with `start` |
| `accumulate` | in | 1 | Skip `CLEAR` and add onto the accumulators; sampled with `start` |
| `busy` | out | 1 | High in `CLEAR`, `COMPUTE` and `CAPTURE` |
| `done` | out | 1 | High in `DONE`: C is readable |
| `clear` | out | 1 | High in `CLEAR`, to the array |
| `en` | out | 1 | High in `COMPUTE`, to the array and both skew buffers |
| `step` | out (reg) | `STEP_W` | Compute step, 0 to `T − 1` in `COMPUTE`, with `T = run_k_len + 2N − 2`; 0 elsewhere |
| `run_k_len` | out (reg) | `K_LEN_W` | `k_len` sampled at the last accepted `start`, to both skew buffers |
| `capture` | out | 1 | High in `CAPTURE`, to the output buffer |
| `cycle_count` | out (reg) | `CYC_W` | Cycles spent busy in the current or last run |

`busy`, `done`, `clear`, `en` and `capture` are decoded from the state register only (Moore outputs), so they change only at clock edges.

### 6.7 `systolic_top` — `rtl/top/systolic_top.v` (#4)

Parameters: `N`, `K_MAX`, `DATA_W`, `ACC_W`, `CYC_W`. This is the matrix data interface the host sees.

| Port | Dir | W | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset |
| `a_we`, `a_addr`, `a_wdata` | in | 1, `OP_ADDR_W`, `DATA_W` s | Write one element of A (section 8) |
| `b_we`, `b_addr`, `b_wdata` | in | 1, `OP_ADDR_W`, `DATA_W` s | Write one element of B (section 8) |
| `start` | in | 1 | Begin a run |
| `k_len` | in | `K_LEN_W` | Inner length of the run, 1 to `K_MAX`; sampled with `start` |
| `accumulate` | in | 1 | Add this run's products onto the previous C; sampled with `start` |
| `busy` | out | 1 | A multiplication is running |
| `done` | out | 1 | C is valid on the read port |
| `c_addr` | in | `ADDR_W` | Row-major address of the element of C to read |
| `c_rdata` | out (comb) | `ACC_W` s | `C[c_addr / N][c_addr % N]` |
| `cycle_count` | out | `CYC_W` | Busy cycles of the last run |

Wiring: each buffer's `we` is the host's write enable ANDed with `!busy`, so writes during a run are ignored and cannot corrupt the operands in flight. The host's `k_len` and `accumulate` go to the controller. The controller's `en`, `step` and `run_k_len` go to both buffers, `clear` and `en` go to the array, and `capture` goes to the output buffer.

### 6.8 `seq_matmul` — `rtl/baseline/seq_matmul.v` (#64)

The sequential baseline for the speed-up. Its parameters, ports and address map are exactly those of `systolic_top` (6.7 and section 8), so any host, testbench or the demo can drive either design. Inside it has one multiplier and one adder, that is one MAC, and it computes C one element at a time.

- **Order.** Row-major over the elements of C. Each element takes `k_len` cycles, one product per cycle, for k = 0 to `k_len − 1`.
- **Cycles.** A run is busy for exactly `N²·k_len` cycles (64 for N = `k_len` = 4), normal or accumulate, with no clear or capture cycle. `cycle_count` holds `N²·k_len` in `DONE`.
- **Arithmetic.** The same as `mac.v` (section 4): the signed product at its natural width, sign-extended to `ACC_W`. Both designs give bit-identical C.
- **Starting value.** A normal run starts each element from its first product. An accumulate run starts each element from its stored value in C, so it adds onto the previous run's C exactly as the array does.
- **C.** Each finished element is written to C in the cycle of its last product. C is valid from `done` until the next `start`. During a run it changes element by element, and a read returns a mix of old and new elements. The array keeps the old C readable until `CAPTURE` (7.5); matching that here would need a second N×N result store, which would inflate the baseline's area in the synthesis comparison.
- **Control.** States `IDLE`, `COMPUTE` and `DONE`: `busy` is high in `COMPUTE` and `done` in `DONE`. `start`, `k_len` and `accumulate` follow the same rules as the array (7.5), including ignoring a `start` whose `k_len` is out of range. Host writes are ignored while `busy` is high, and A and B keep their contents between runs. Reset zeroes A, B, C and `cycle_count`.

## 7. Timing

### 7.1 When operands meet

Number the `COMPUTE` cycles with the step `t = 0, 1, …, T − 1`. The skew buffers put `A[i][t − i]` on lane i of `a_left` and `B[t − j][j]` on lane j of `b_top`. Each PE adds one cycle of delay in each direction, so in step t PE (i, j) sees

```
a_in = A[i][t - i - j]      b_in = B[t - i - j][j]
```

Both carry the same index `k = t − i − j`, so PE (i, j) adds the term `A[i][k] * B[k][j]` in step `t = i + j + k`. Outside `0 <= k < k_len` both operands are zero and the product adds nothing.

PE (i, j) is busy from step `i + j` to step `i + j + k_len − 1`. The last PE, (N−1, N−1), adds its last term in step `k_len + 2N − 3`, so `COMPUTE` lasts

```
T = k_len + 2N - 2 cycles        (10 for N = k_len = 4, 22 for k_len = K_MAX = 16)
```

The controller computes `T` from the `k_len` it sampled at `start`, so each run can have a different length.

**Why an accumulate run can skip `CLEAR`.** `CLEAR` zeroes the accumulators and the forwarding registers. An accumulate run wants the accumulators as they are, and its forwarding registers are already zero. In the last step of any run, PE (i, j) forwards the operands with `k = k_len + 2N − 3 − i − j`, which is at least `k_len`, so they are zero, for every PE except (N−1, N−1). That PE's outputs drive nothing. After reset, every register is zero anyway.

### 7.2 Edge inputs for N = `k_len` = 4

`Aik` means `A[i][k]`, and `·` means 0.

| Step t | `a_left[0]` | `a_left[1]` | `a_left[2]` | `a_left[3]` | `b_top[0]` | `b_top[1]` | `b_top[2]` | `b_top[3]` |
|---|---|---|---|---|---|---|---|---|
| 0 | A00 | · | · | · | B00 | · | · | · |
| 1 | A01 | A10 | · | · | B10 | B01 | · | · |
| 2 | A02 | A11 | A20 | · | B20 | B11 | B02 | · |
| 3 | A03 | A12 | A21 | A30 | B30 | B21 | B12 | B03 |
| 4 | · | A13 | A22 | A31 | · | B31 | B22 | B13 |
| 5 | · | · | A23 | A32 | · | · | B32 | B23 |
| 6 | · | · | · | A33 | · | · | · | B33 |
| 7–9 | · | · | · | · | · | · | · | · |

The edges go quiet after step 6, but the last operands are still moving through the array until step 9. Any other `k_len` gives the same pattern: lane l carries `k = t − l` while `0 <= k < k_len`, so the edges go quiet after step `k_len + N − 2` and the array drains until step `k_len + 2N − 3`.

The wavefront in step 3 shows which term `k` each PE is adding (`–` means the PE is idle):

| | j = 0 | j = 1 | j = 2 | j = 3 |
|---|---|---|---|---|
| **i = 0** | k = 3 | k = 2 | k = 1 | k = 0 |
| **i = 1** | k = 2 | k = 1 | k = 0 | – |
| **i = 2** | k = 1 | k = 0 | – | – |
| **i = 3** | k = 0 | – | – | – |

### 7.3 Controller FSM

```mermaid
stateDiagram-v2
  [*] --> IDLE
  IDLE --> CLEAR: start, accumulate low
  IDLE --> COMPUTE: start, accumulate high
  CLEAR --> COMPUTE
  COMPUTE --> COMPUTE: step != T-1
  COMPUTE --> CAPTURE: step == T-1
  CAPTURE --> DONE
  DONE --> CLEAR: start, accumulate low
  DONE --> COMPUTE: start, accumulate high
```

A `start` is **accepted** when it arrives in `IDLE` or `DONE` with 1 ≤ `k_len` ≤ `K_MAX`. On an accepted start, `run_k_len <= k_len`, and that run's `T` is `run_k_len + 2N − 2`. A `start` with `k_len` = 0 or above `K_MAX` is ignored: the state, `run_k_len` and `cycle_count` do not change, and `busy` stays low, which the host can see.

| State | Outputs high | Next state | `step` at the edge | `cycle_count` at the edge |
|---|---|---|---|---|
| `IDLE` | none | On an accepted `start`: `CLEAR` if `accumulate` is low, `COMPUTE` if it is high. Otherwise `IDLE` | 0 | 0 on an accepted `start`, else hold |
| `CLEAR` | `busy`, `clear` | `COMPUTE` | 0 | +1 |
| `COMPUTE` | `busy`, `en` | `CAPTURE` if `step == T − 1`, else `COMPUTE` | +1, or 0 when leaving | +1 |
| `CAPTURE` | `busy`, `capture` | `DONE` | 0 | +1 |
| `DONE` | `done` | As in `IDLE`, staying in `DONE` without an accepted `start` | 0 | As in `IDLE` |

`CLEAR` takes one cycle, so the accumulators and forwarding registers are zero before step 0. `CAPTURE` takes one cycle, because the last product lands in the accumulators at the end of step `T − 1` and can be copied only at the next edge. The state encoding is up to the implementer.

### 7.4 One run, cycle by cycle (N = `k_len` = 4)

Cycle c0 is the cycle in which the host holds `start` high.

| Cycle | State | `busy` | `done` | `clear` | `en` | `step` | `capture` | `cycle_count` | At the end of the cycle |
|---|---|---|---|---|---|---|---|---|---|
| c0 | `IDLE` | 0 | 0 | 0 | 0 | 0 | 0 | old value | `start` accepted, `cycle_count <= 0` |
| c1 | `CLEAR` | 1 | 0 | 1 | 0 | 0 | 0 | 0 | accumulators and forwarding registers cleared |
| c2 | `COMPUTE` | 1 | 0 | 0 | 1 | 0 | 0 | 1 | PE (0, 0) adds A00·B00 |
| c3 – c10 | `COMPUTE` | 1 | 0 | 0 | 1 | 1 – 8 | 0 | 2 – 9 | the wavefront moves across the array |
| c11 | `COMPUTE` | 1 | 0 | 0 | 1 | 9 | 0 | 10 | PE (3, 3) adds A33·B33 |
| c12 | `CAPTURE` | 1 | 0 | 0 | 0 | 0 | 1 | 11 | output buffer loads all accumulators |
| c13 | `DONE` | 0 | 1 | 0 | 0 | 0 | 0 | 12 | C is readable |

In general a normal run keeps `busy` high for `T + 2 = k_len + 2N` cycles (12 for N = `k_len` = 4), and `cycle_count` holds that number in `DONE`. Of those cycles, `T` are compute cycles with `en` high.

### 7.5 Handshake rules

- `start` is a one-cycle pulse. It is sampled only in `IDLE` and `DONE` and ignored while `busy` is high. If it is still high when the controller reaches `DONE`, a new run starts at once, so drop it after one cycle.
- `k_len` and `accumulate` are sampled in the cycle a `start` is accepted. Changing them during a run has no effect. A `start` with `k_len` outside 1 to `K_MAX` is ignored (7.3).
- With `accumulate` low, a run starts with `CLEAR` and computes C = A × B for its operands. With `accumulate` high, it skips `CLEAR` and adds A × B onto the accumulators, which hold the C of the last completed run (zero after reset).
- Writes to A and B are accepted only while `busy` is low; the top level ignores them during a run. A and B keep their contents between runs, so a host can replace just one operand before the next `start`, for example keep A and load a new B.
- C is valid while `done` is high. It stays readable after the next `start`, until that run's `CAPTURE` cycle replaces it. (The baseline differs here; see 6.8.)
- `rst_n` low at a rising edge returns the controller to `IDLE` and zeroes A, B, the accumulators, the results, `run_k_len` and `cycle_count`. After reset, every address of C reads 0.

### 7.6 An accumulate run, cycle by cycle (N = `k_len` = 4)

The previous run has finished, so the controller is in `DONE`, and the host holds `start` high with `accumulate` high in cycle c0.

| Cycle | State | `busy` | `done` | `clear` | `en` | `step` | `capture` | `cycle_count` | At the end of the cycle |
|---|---|---|---|---|---|---|---|---|---|
| c0 | `DONE` | 0 | 1 | 0 | 0 | 0 | 0 | old value | `start` accepted, `cycle_count <= 0` |
| c1 | `COMPUTE` | 1 | 0 | 0 | 1 | 0 | 0 | 0 | PE (0, 0) adds A00·B00 onto its old sum |
| c2 – c9 | `COMPUTE` | 1 | 0 | 0 | 1 | 1 – 8 | 0 | 1 – 8 | the wavefront moves across the array |
| c10 | `COMPUTE` | 1 | 0 | 0 | 1 | 9 | 0 | 9 | PE (3, 3) adds A33·B33 |
| c11 | `CAPTURE` | 1 | 0 | 0 | 0 | 0 | 1 | 10 | output buffer loads the new sums |
| c12 | `DONE` | 0 | 1 | 0 | 0 | 0 | 0 | 11 | C = old C + A × B is readable |

An accumulate run keeps `busy` high for `T + 1 = k_len + 2N − 1` cycles (11 here), one fewer than a normal run. The old C stays readable until c11.

## 8. Address map

Each matrix has its own port and row-major addresses. A is stored as N rows of `K_MAX` elements and B as `K_MAX` rows of N elements, so a run of any `k_len` uses the first `k_len` columns of A and the first `k_len` rows of B.

| Port | Element | Address | Example (N = 4, `K_MAX` = 16) |
|---|---|---|---|
| `a_addr` | `A[r][k]`, r < N, k < `K_MAX` | `r*K_MAX + k` | `A[2][1]` is at 33 |
| `b_addr` | `B[k][c]`, k < `K_MAX`, c < N | `k*N + c` | `B[5][3]` is at 23 |
| `c_addr` | `C[r][c]` | `r*N + c` | `C[3][3]` is at 15 |

Writes to A or B at or above `N*K_MAX` are ignored, and C addresses at or above N² read 0. Elements with k ≥ `k_len` are never used, so a host loads only the N·`k_len` elements of A and of B that a run needs. The A and B ports are independent, so both blocks load together in N·`k_len` cycles (16 for `k_len` = 4, 64 for `k_len` = 16). C is read one element per cycle, in N² = 16 cycles. With `K_MAX` = N the map is the Phase 1 one.

## 9. Golden test vectors

`model/gen_vectors.py` (#14, #72) writes three vector sets, and the testbenches read them with `$readmemh`. Both sides follow these formats so they work together without further agreement. The generator's flags are up to #72; the Makefile's `vectors` target writes all three sets.

### 9.1 Phase 1 set: `sim/vectors/`

```sh
python model/gen_vectors.py --n 4 --random 100 --seed 1 --out sim/vectors
```

`sim/vectors/` is generated and gitignored.

| File | Lines | Each line |
|---|---|---|
| `config.hex` | 2 | Line 0 is N; line 1 is the number of cases. 8 hex digits each |
| `a.hex` | cases × N × N | One element of A: `DATA_W / 4` hex digits (2), two's complement |
| `b.hex` | cases × N × N | One element of B, same format |
| `c.hex` | cases × N × N | One expected element of C: `ACC_W / 4` hex digits (8), two's complement |
| `manifest.txt` | – | For people: N, the seed, and the index and name of every case |

Line `case*N*N + r*N + c` of each file holds element (r, c) of that case. Negative values are written in two's complement at the file's width, so −1 is `ff` in `a.hex` and −65,024 is `ffff0200` in `c.hex`. The testbench checks that N in `config.hex` matches its own parameter.

Directed cases come first, in this order, followed by the random cases:

| Index | Name | A | B | Expected C |
|---|---|---|---|---|
| 0 | `identity` | random | identity | C = A |
| 1 | `zero` | random | all zero | all zero |
| 2 | `ones` | all 1 | all 1 | every element K |
| 3 | `max_negative` | all −128 | all −128 | every element K × 16,384 (65,536 for K = 4) |
| 4 | `max_mixed` | all −128 | all 127 | every element −K × 16,256 (−65,024 for K = 4) |
| 5 | `known` | 1 to N², row-major | A transposed | worked by hand in the report |
| 6 and on | `random_<n>` | uniform over −128 to 127 | uniform over −128 to 127 | from the model |

Random values come from `numpy.random.default_rng(seed)`, so a seed always reproduces the same cases. This set is unchanged in Phase 2. With `K_MAX` > N, a testbench writes `A[r][k]` of this set at address `r*K_MAX + k` (section 8) and runs every case with `k_len` = N.

### 9.2 K ≠ N set: `sim/vectors/kn/`

Single runs with `k_len` from 1 to `K_MAX`, stored in the hardware layout, so a testbench can copy each case to the A and B ports address for address.

| File | Lines | Each line |
|---|---|---|
| `config.hex` | 3 | N, the number of cases, `K_MAX`. 8 hex digits each |
| `klen.hex` | cases | That case's `k_len`, 8 hex digits |
| `a.hex` | cases × N × `K_MAX` | Line `case*N*K_MAX + r*K_MAX + k` holds `A[r][k]`, 2 hex digits |
| `b.hex` | cases × `K_MAX` × N | Line `case*K_MAX*N + k*N + c` holds `B[k][c]`, 2 hex digits |
| `c.hex` | cases × N × N | Line `case*N*N + r*N + c` holds the expected `C[r][c]`, 8 hex digits |
| `manifest.txt` | – | N, `K_MAX`, the seed, and the index, name and `k_len` of every case |

Elements of A and B with k ≥ `k_len` are **random filler**, not zero. The hardware must ignore them, so a design that reads past `k_len` fails these checks. The expected C uses only k < `k_len`.

Cases, in order:

1. Directed cases, for each `k_len` in (1, N − 1, N + 1, `K_MAX`), skipping repeats and values outside 1 to `K_MAX`:
   - `ones_k<k>`: A and B all 1, so every element of C is `k_len`.
   - `max_negative_k<k>`: A and B all −128, so every element is `k_len` × 16,384.
   - `random_k<k>`: uniform over −128 to 127.
2. `random_<n>`: random cases with `k_len` uniform over 1 to `K_MAX`, 100 by default.

### 9.3 Tiled set: `sim/vectors/tiled/`

Whole products C = A·B, with A of size M×K and B of size K×P, for the tiling tests (section 12). The testbench cuts them into tiles and chunks itself.

| File | Lines | Each line |
|---|---|---|
| `config.hex` | 3 | N, the number of products, `K_MAX`. 8 hex digits each |
| `dims.hex` | 3 × products | M, K and P of each product, in that order. 8 hex digits each |
| `a.hex` | Σ M·K | Each product's A, row-major, the products back to back. 2 hex digits |
| `b.hex` | Σ K·P | Each product's B, row-major, back to back. 2 hex digits |
| `c.hex` | Σ M·P | Each product's expected C, row-major, back to back. 8 hex digits |
| `manifest.txt` | – | N, `K_MAX`, the seed, and the index, name and dimensions of every product |

A product's lines start where the previous product's end, so a testbench finds them by summing the earlier dimensions. Products, in order (sizes for N = 4 and `K_MAX` = 16):

| Name | M × K × P | Shape in general | What it exercises |
|---|---|---|---|
| `exact` | 8 × 8 × 8 | 2N × 2N × 2N | Four tiles, one chunk, no padding |
| `pad_all` | 5 × 7 × 6 | (N + 1) × (2N − 1) × (N + 2) | Zero padding on every edge |
| `chunks` | 4 × 40 × 4 | N × (5·`K_MAX`/2) × N | Three chunks (16, 16, 8): accumulate runs |
| `pad_chunks` | 9 × 33 × 7 | (2N + 1) × (2·`K_MAX` + 1) × (2N − 1) | Padding plus a last chunk of length 1 |
| `single` | 1 × 1 × 1 | 1 × 1 × 1 | The smallest product |
| `max_negative_long` | 4 × 64 × 4 | N × 4·`K_MAX` × N | A and B all −128: every element is 64 × 16,384 = 1,048,576, so it must not overflow |
| `random_<n>` | random | M, P uniform over 1 to 3N; K uniform over 1 to 3·`K_MAX` | 20 by default |

## 10. Verification plan

Every testbench is self-checking and ends with one summary line, which the Makefile (#17) and CI look for:

```
PASS tb_<module> <passed>/<total>
FAIL tb_<module> <failed> of <total> checks failed
```

On any failure the testbench also calls `$fatal(1, ...)`, so the simulator exits with an error.

| Testbench | Module | It must check | Issue |
|---|---|---|---|
| `tb_mac` | `mac` | Signed products including −128 × −128 and −128 × 127; an accumulation chain; `clear` in the middle of a chain; `en` low holds; reset | #6 |
| `tb_pe` | `pe` | Forwarding takes exactly one enabled cycle; everything holds while `en` is low; accumulation over K steps; `clear` zeroes all three registers | #6 |
| `tb_input_skew_buffer` | `input_skew_buffer` | Every lane in every step 0 to T − 1, for both `COLUMN_LANES` values, for `k_len` = 1, N, N + 1 and `K_MAX` (table 7.2 for `k_len` = N); lanes stay zero beyond `k_len` while the storage holds nonzero filler; zeros while `en` is low; writes to every address | #10, #68 |
| `tb_output_buffer` | `output_buffer` | `capture` loads all N² values; values hold without `capture`; every address reads back | #10 |
| `tb_sa_controller` | `sa_controller` | State sequence; `T = k_len + 2N − 2` compute cycles and `k_len + 2N` busy cycles for `k_len` = 1, N and `K_MAX`; accumulate starts from `IDLE` and from `DONE` skip `CLEAR` and take `k_len + 2N − 1` busy cycles; a `start` with `k_len` = 0 or `K_MAX` + 1 is ignored; `run_k_len` holds while `k_len` changes during a run; `cycle_count`; `start` ignored while busy; back-to-back runs; reset in the middle of a run; for N = 3 and N = 4 | #7, #65 |
| `tb_systolic_array` | `systolic_array` | Identity, all-ones, a known product and negative values, with skewed edge inputs driven by the testbench; the directed K ≠ N cases of 9.2 and random `k_len`, against the testbench's own reference, since the array has no `k_len` input; products split into two and three chunks, run without a clear between them, give the whole product; N = 3 and N = 4 | #3, #61 |
| `tb_systolic_top` | `systolic_top` | Every case of the Phase 1 set with `k_len` = N, and of the K ≠ N set; `cycle_count == k_len + 2N`; an accumulate run gives old C + A × B after `k_len + 2N − 1` busy cycles; writes, `k_len` and `accumulate` are ignored during a run; a `start` with `k_len` out of range is ignored; back-to-back runs | #11, #62, #69 |
| `tb_tiled` (or part of `tb_systolic_top`) | `systolic_top` | Every product of the tiled set (9.3) through the host ports with the reference schedule of section 12, the whole C compared; cycle counts written to `results/phase2/` | #69 |
| `tb_seq_matmul` | `seq_matmul` | The Phase 1 and K ≠ N sets; a two-chunk product against the full result; `busy` and `cycle_count` equal `N²·k_len`; writes during a run are ignored; a `start` with `k_len` out of range is ignored; back-to-back runs; reset in the middle of a run | #64 |

## 11. Performance model

### 11.1 One run

| Metric | Formula | N = 4, `k_len` = 4 | N = 4, `k_len` = 16 |
|---|---|---|---|
| Compute cycles `T` | `k_len + 2N − 2` | 10 | 22 |
| Busy cycles, normal run | `k_len + 2N` | 12 | 24 |
| Busy cycles, accumulate run | `k_len + 2N − 1` | 11 | 23 |
| Multiply-accumulates in the run | `N²·k_len` | 64 | 256 |
| Peak multiply-accumulates per cycle | `N²` | 16 | 16 |
| PE utilization during compute | `N²·k_len / (N²·T) = k_len / T` | 40% | 72.7% |
| Baseline busy cycles (6.8) | `N²·k_len` | 64 | 256 |
| Speed-up over the baseline, compute only | `N²·k_len / T` | 6.4× | 11.6× |
| Speed-up over the baseline, busy cycles | `N²·k_len / (k_len + 2N)` | 5.3× | 10.7× |
| Loading A and B (section 8) | `N·k_len` | 16 | 64 |

Utilization is 40% at `k_len` = 4 because the wavefront takes 2N − 2 cycles to fill and drain the array. Fill and drain are paid once per run, so utilization and the speed-up grow with `k_len`, towards 100% and N² = 16.

### 11.2 A whole product

For C = A·B with A of size M×K and B of size K×P, tiled as in section 12:

```
tiles  = ceil(M/N) * ceil(P/N)
chunks = ceil(K/K_MAX)            runs = tiles * chunks
```

| Per tile | Array | Baseline |
|---|---|---|
| Busy cycles | `K + chunks·(2N − 1) + 1` | `N²·K` |
| Host cycles with the reference schedule (load + start + busy + read) | `(N + 1)·K + 2N·chunks + 1 + N²` | `N·K + chunks + N²·K + N²` |

Multiply by `tiles` for the whole product. The array's busy cycles are one normal run of `k_len + 2N` plus `chunks − 1` accumulate runs of `k_len + 2N − 1`, summed over the chunks.

Examples for N = 4 and `K_MAX` = 16:

| Product | Tiles × chunks | Array busy | Baseline busy | Busy speed-up | Array host cycles | Baseline host cycles | Host speed-up |
|---|---|---|---|---|---|---|---|
| 4 × 4 × 4 | 1 × 1 | 12 | 64 | 5.3× | 45 | 97 | 2.2× |
| 8 × 8 × 8 | 4 × 1 | 64 | 512 | 8.0× | 260 | 708 | 2.7× |
| 4 × 40 × 4 | 1 × 3 | 62 | 640 | 10.3× | 241 | 819 | 3.4× |

### 11.3 What the model predicts

- The array is fastest relative to the baseline on long inner dimensions, where fill and drain are a small part of each run.
- End to end, loading dominates. A run needs N·`k_len` cycles to load its operands through one-element ports but only `k_len + 2N` to compute, so the host speed-up stays far below the busy speed-up. Wider or double-buffered ports would fix this; they are out of scope (section 15), and the results (#71) should quantify the gap.
- A larger `K_MAX` means fewer chunks and higher utilization, at the cost of N·`K_MAX`·`DATA_W` bits of storage for each operand.

The RTL must reproduce the per-run cycle counts exactly in simulation (#65, #69, #64), and the performance model (#73) must match every measured run. Phase 1's estimate of about 44 cycles for one 4×4 product with I/O is 45 in this model, which also counts the `start` cycle.

## 12. Tiling products larger than the array

The hardware computes one N×N tile of C per run, over an inner length of at most `K_MAX`. A host computes C = A·B for any A of size M×K and B of size K×P like this:

1. Split C into `ceil(M/N) × ceil(P/N)` output tiles. Tile (ti, tj) covers rows `ti·N` to `ti·N + N − 1` and columns `tj·N` to `tj·N + N − 1` of C.
2. Split the inner dimension into `ceil(K/K_MAX)` chunks. Chunk c covers k = `c·K_MAX` to `c·K_MAX + k_len_c − 1`, with `k_len_c = min(K_MAX, K − c·K_MAX)`. Every chunk is full except possibly the last.
3. For each tile, for each chunk c in order:
   - Write the N×`k_len_c` block of A (the tile's rows, the chunk's columns) and the `k_len_c`×N block of B (the chunk's rows, the tile's columns), at the addresses of section 8 relative to the block.
   - Write rows of A beyond M and columns of B beyond P as 0. This is the zero padding; it must be written, because the stores keep old values.
   - Pulse `start` with `k_len = k_len_c`, and `accumulate` low for chunk 0 and high for every later chunk.
   - Wait for `done`.
4. After the last chunk, read the N×N tile of C and keep the rows below M and the columns below P.

The accumulate start keeps each tile's partial sums in the PEs between chunks, so no partial sum leaves the array and only the finished tile is read. Padding costs the same time as real work. The baseline runs the same procedure through the same ports.

**Reference host schedule.** The performance model (11.2) and the measured cycle counts (#69) use this schedule:

1. Each run writes its A and B blocks in parallel, one element of each per cycle, in N·`k_len` cycles.
2. It then pulses `start` for one cycle and waits through the busy cycles.
3. The next run's writes start in the first `DONE` cycle.
4. After a tile's last chunk, the host reads C one element per cycle, starting in the first `DONE` cycle.

A host may do better, for example by keeping A when only B changes, or by loading the next tile's operands while it reads C. Report such schedules separately from the reference numbers.

## 13. Synthesis targets and metrics

Phase 2 reports resources and maximum frequency from a fully open-source flow (#75). No board is available, so the design is synthesized, placed and routed, but not run on hardware.

- **Device.** Lattice ECP5 LFE5U-25F, speed grade 6, 256-ball caBGA package (`nextpnr-ecp5 --25k --package CABGA256 --speed 6`). It has 24K LUT4s and 28 MULT18X18D multiplier blocks.
- **Flow.** Yosys `synth_ecp5 -top <module>`, then `nextpnr-ecp5` with a 100 MHz target on `clk` and `--seed 1`, so every number is reproducible. No pins are constrained; nextpnr places the I/O. At N = 4 the top level has 109 pins.
- **Designs.** `systolic_top` for N = 2, 3 and 4, and `seq_matmul` at N = 4, all with the default `DATA_W`, `ACC_W`, `K_MAX` and `CYC_W`. N = 8 needs 64 multipliers, more than the 28 blocks, so try it with the extra multipliers in LUTs and report it only if it fits.
- **Metrics.** One row per design in `results/phase2/synth/summary.csv`: LUT4s, flip-flops, MULT18X18D blocks and block RAMs used, from the nextpnr utilization report, and the post-route Fmax of `clk`.
- **Throughput.** Peak multiply-accumulates per second are N²·Fmax for the array and Fmax for the baseline. The effective rate of a run is `N²·k_len / (k_len + 2N)`·Fmax. The results (#71) compare both designs per second and per LUT, not only per cycle.
- **Critical path.** The skew lanes are combinational, so the longest path probably runs from `step` or `run_k_len` through the lane multiplexer, the multiplier and the adder into the accumulator. Report the path nextpnr prints (#78). Registering the lanes would shorten it at the cost of one more cycle per run; that is out of scope unless the results justify it.

## 14. Phase 2 build order

`dev` must lint and pass every testbench after each merge, so the changes land in this order:

1. **This spec (#60).** It adds `SA_K_MAX` to `sa_params.vh` and changes no RTL.
2. **Controller (#65) and skew buffers (#68), in parallel.** Each PR also updates its instance in `systolic_top` so the top level keeps its Phase 1 behaviour and `tb_systolic_top` passes unchanged:
   - Pass `K_MAX = N`.
   - Tie the controller's `k_len` to N and its `accumulate` to 0.
   - Drive the buffers' `k_len` from the controller's `run_k_len` once both are in, and tie it to N until then.
   - Keep `make lint` clean.
3. **Top level (#62).** It adds the `k_len` and `accumulate` ports, uses the default `K_MAX`, and moves `tb_systolic_top`'s A writes to the new address map with `k_len` = N.
4. **End-to-end tests (#69), array checks (#61) and the demo (#70)** follow, on top of #62 and the vector sets from #72.

The baseline (#64), the golden model (#72) and the synthesis flow (#75) do not depend on this order. The baseline is standalone, the vectors need only sections 8 and 9, and synthesis runs on whatever `dev` holds.

## 15. Out of scope

- Rounding and saturating results back to `DATA_W` bits.
- Double-buffered or wider A, B and C ports that overlap loading, computing and reading.
- Registered skew lanes, unless the synthesis results justify them (section 13).
- Running on an FPGA board, since none is available, and vendor tools such as Vivado.
