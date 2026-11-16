# Golden model and test vectors (#14)

Python reference for `C = A × B` and the generator of the vectors that
`tb/tb_systolic_top.v` (#11) reads. The file format is the one in
[`docs/spec.md` section 9](../docs/spec.md#9-golden-test-vectors).

| File | What it does |
|---|---|
| `golden_model.py` | `matmul`: the reference product, with range checks on operands (`DATA_W`) and results (`ACC_W`). `simulate_output_stationary`: a cycle-level model of the N×N array with the spec's skew and forwarding registers. `edge_inputs`: the lane values of table 7.2. `to_hex` / `from_hex`: two's complement hex. |
| `gen_vectors.py` | Writes `config.hex`, `a.hex`, `b.hex`, `c.hex` and `manifest.txt`. |
| `test_golden_model.py` | Self-tests against hand-worked values and the spec's numbers. |
| `requirements.txt` | NumPy. |

## Use

```sh
python -m pip install -r model/requirements.txt
make vectors                                   # N=4, 100 random cases, seed 1 -> build/vectors
python model/gen_vectors.py --n 4 --random 100 --seed 1 --out sim/vectors   # same thing by hand
python -m unittest discover -s model -v       # model self-tests
```

`make vectors` writes to `build/vectors` and links `sim/vectors` to it, so
testbenches can always `$readmemh("sim/vectors/a.hex", ...)`.

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
