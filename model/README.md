# Golden model and test vectors (#14, #72)

Python reference for `C = A × B` and the generator of the vectors the
testbenches read. The file formats are the ones in
[`docs/spec.md` section 9](../docs/spec.md#9-golden-test-vectors): the Phase 1
set, the K ≠ N set and the tiled set.

| File | What it does |
|---|---|
| `golden_model.py` | `matmul`: the reference product, with range checks on operands (`DATA_W`) and results (`ACC_W`). `simulate_output_stationary`: a cycle-level model of the N×N array with the spec's skew and forwarding registers, for any `k_len`, and for accumulate runs through `acc_init`. `compute_cycles` / `busy_cycles`: the run lengths of spec 7.4 and 7.6. `plan_tiles`, `tiled_matmul`, `simulate_tiled`: the tiling procedure of spec section 12. `edge_inputs`: the lane values of table 7.2. `to_hex` / `from_hex`: two's complement hex. |
| `gen_vectors.py` | Writes the three vector sets: the Phase 1 set in `--out`, the K ≠ N set in `--out/kn/` and the tiled set in `--out/tiled/`. |
| `test_golden_model.py` | Self-tests against hand-worked values and the spec's numbers. |
| `speedup.py` | Joins the measured tiled-product cycles of the array (`results/phase2/tiled_cycles.csv`) and the baseline (`results/phase2/baseline_cycles.csv`) into `results/phase2/speedup.csv`, with the busy-cycle and end-to-end speed-up of every product. Run it after `make test`. |
| `demo.py` | The live demonstration behind `make demo`: one product of any size on `systolic_top` and `seq_matmul`, checked against NumPy, with both designs' cycle counts and the speed-up. |
| `requirements.txt` | NumPy. |

## Use

```sh
python -m pip install -r model/requirements.txt
make vectors                                   # all three sets, N=4, K_MAX=16, seed 1 -> build/vectors
python model/gen_vectors.py --n 4 --random 100 --seed 1 --out sim/vectors   # same thing by hand
python model/gen_vectors.py --sets kn --kn-random 10 --out /tmp/v           # one set, fewer cases
python -m unittest discover -s model -v       # model self-tests
python model/speedup.py                        # measured speed-up, after make test
make demo                                      # random 8x20x8 product on both designs
make demo M=9 K=33 P=7 SEED=4                  # another size and seed
make demo A=my_a.txt B=my_b.txt WAVES=1        # your own matrices, then open the last tile
```

`make vectors` writes to `build/vectors` and links `sim/vectors` to it, so
testbenches can always `$readmemh("sim/vectors/a.hex", ...)`,
`"sim/vectors/kn/a.hex"` or `"sim/vectors/tiled/a.hex"`.

| Flag | Default | Meaning |
|---|---|---|
| `--n` | 4 | Array size N |
| `--k-max` | 16 | `K_MAX`, the largest `k_len` of one run (`SA_K_MAX`); at least N |
| `--random` | 100 | Random cases in the Phase 1 set |
| `--kn-random` | 100 | Random cases in the K ≠ N set |
| `--tiled-random` | 20 | Random products in the tiled set |
| `--seed` | 1 | Seed of all three sets |
| `--sets` | `phase1 kn tiled` | Which sets to write |

## Cases

Six directed cases come first, then the random ones (`random_0`, `random_1`, ...):

| Index | Name | A | B | Expected C (N = K = 4) |
|---|---|---|---|---|
| 0 | `identity` | random | identity | C = A |
| 1 | `zero` | random | zero | all 0 |
| 2 | `ones` | all 1 | all 1 | all 4 |
| 3 | `max_negative` | all −128 | all −128 | all 65,536 |
| 4 | `max_mixed` | all −128 | all 127 | all −65,024 (`ffff0200`) |
| 5 | `known` | 1 to 16, row-major | A transposed | `C[0][0]` = 30, `C[3][3]` = 846 |

Element (r, c) of case `i` is on line `i*N*N + r*N + c` of each `.hex` file.
`manifest.txt` lists the first line of every case, so a failing line number
in the testbench log can be traced back to a case name.

## Why two models

`matmul` alone would give correct expected values, but it says nothing about
timing. `simulate_output_stationary` moves operands through forwarding
registers exactly as the RTL does and must reach the same C after exactly
`T = K + 2N − 2` steps. The generator refuses to write vectors if the two
disagree, so the timing contract in the spec is checked in software before
any RTL runs. When a PE result is wrong in simulation, pass a list as
`trace=` to see which operands each PE should have multiplied in each step.

All random values come from one `numpy.random.default_rng(seed)`, including
the random A of `identity` and `zero`. The same seed always gives the same
files, and the seed is printed in `manifest.txt`.

## K ≠ N set: `sim/vectors/kn/` (#72)

Single runs with `k_len` from 1 to `K_MAX`, in the hardware's layout: A is
N×`K_MAX` and B is `K_MAX`×N, so a testbench copies each case to the A and B
ports address for address (spec section 8). Elements with k ≥ `k_len` are
random filler, not zero: a design that reads past `k_len` fails. The expected
C uses only k < `k_len`, and the cycle-level model must reach it in
`k_len + 2N − 2` steps.

Directed cases come first, three for each `k_len` in (1, N − 1, N + 1,
`K_MAX`) = (1, 3, 5, 16): `ones_k<k>` (every element of C is `k_len`),
`max_negative_k<k>` (`k_len` × 16,384) and `random_k<k>`. Then `random_<n>`
with `k_len` uniform over 1 to `K_MAX`. `manifest.txt` lists each case's
`k_len`, its compute and busy cycles, and its first line in each file.

## Tiled set: `sim/vectors/tiled/` (#72)

Whole products C = A·B with A of size M×K and B of size K×P, back to back in
each file; `dims.hex` gives M, K and P of each. For N = 4 and `K_MAX` = 16:

| Index | Name | M × K × P | What it exercises |
|---|---|---|---|
| 0 | `exact` | 8 × 8 × 8 | Four tiles, one chunk, no padding |
| 1 | `pad_all` | 5 × 7 × 6 | Zero padding on every edge |
| 2 | `chunks` | 4 × 40 × 4 | Three chunks (16, 16, 8): accumulate runs |
| 3 | `pad_chunks` | 9 × 33 × 7 | Padding plus a last chunk of length 1 |
| 4 | `single` | 1 × 1 × 1 | The smallest product |
| 5 | `max_negative_long` | 4 × 64 × 4 | All −128: every element is 1,048,576 |
| 6 and on | `random_<n>` | M, P from 1 to 12, K from 1 to 48 | 20 by default |

The expected C is `matmul` on the whole matrices. Before writing, the
generator also runs every product through `tiled_matmul` (the section 12
procedure: tiles in row-major order, every chunk of a tile before the next
tile, zero padding) and replays each run on the cycle-level model with
accumulate runs carrying the sums across chunks. `manifest.txt` gives each
product's tiles, chunks and first line in `a.hex`, `b.hex` and `c.hex`.

Each set has its own random generator, seeded from `--seed` and the set, so
the Phase 1 files are byte-identical to Phase 1 and adding cases to one set
never changes another.

## Performance model: `perf_model.py` (#73)

Predicts every cycle count of [`docs/spec.md` section 11](../docs/spec.md#11-performance-model),
checks the predictions against the cycle counts the testbenches write, and
draws the report figures. Run it from the repository root:

```sh
python model/perf_model.py               # check measurements, write figures and sweep
python model/perf_model.py --check-only  # only check measurements
```

It has two models, like the golden model:

- **Closed form**, from spec 11.1 and 11.2. One array run is busy for
  `k_len + 2N` cycles, or `k_len + 2N − 1` for an accumulate run. One
  baseline run is busy for `N²·k_len` cycles. For a whole product, each tile
  is busy for `K + chunks·(2N − 1) + 1` cycles, and takes
  `(N + 1)·K + 2N·chunks + 1 + N²` host cycles once loading and readout are
  included.
- **Schedule** (`schedule_cycles`). Walks the runs of `plan_tiles` one by one
  under the reference host schedule of spec section 12, and adds up loads,
  starts, busy cycles and readouts.

The self-tests check that the two models agree for every shape they try, and
that the closed form gives the spec's worked examples (45, 260 and 241 host
cycles).

**Measured files.** For each file in `MEASURED`, every row is compared with
the model, and the script exits with 1 if any value differs. A file that has
not been measured yet is reported as `SKIP`. These columns are understood:

| Columns | Checked against |
|---|---|
| `busy_cycles`, `cycle_count`, optional `k_len` (default N), `accumulate` (default 0), `n` | One run: `k_len + 2N` or `k_len + 2N − 1` (array), `N²·k_len` (baseline) |
| `compute_cycles` | `k_len + 2N − 2` (array) |
| `m`, `k`, `p` with `busy_cycles` and optional `host_cycles` | A whole tiled product (spec 11.2) |
| `design` (`array` or `baseline`) | Overrides the file's design for that row |

**Outputs** in `results/phase2/figures/`, each as PDF for the report and PNG:

| File | Shows |
|---|---|
| `cycles_vs_size` | Busy and host cycles of S×S×S products, array against baseline, with the measured runs marked |
| `speedup_vs_n` | Busy-cycle speed-up of one N×N tile for N = 2 to 8 and K = 4, 8, 16, against the N² peak |
| `utilization_vs_k` | PE utilization during compute for K = 1 to 32 and N = 2, 4, 8; it drops where a second chunk starts |
| `perf_sweep.csv` | Every metric for N = 2 to 8 and K = 1 to 32 |

## Demo

`make demo` runs `model/demo.py`, which writes the product to `build/demo/`, compiles `tb/demo.v` once for `systolic_top` and once for `seq_matmul`, and runs both through the host procedure of spec section 12. It prints A, B and C, the NumPy check, the busy and total cycles of both designs and the speed-up, and ends with `PASS demo` or `FAIL demo`. A matrix file has one row per line, integers from −128 to 127 separated by spaces or commas; lines starting with `#` are ignored. Products up to 64×64×64 run in a few seconds.
