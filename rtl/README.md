# RTL

Synthesizable Verilog-2005 only. Style rules are in [`CONTRIBUTING.md`](../CONTRIBUTING.md#7-verilog-style), and the timing and interface contract is in [`docs/spec.md`](../docs/spec.md).

| Folder | Module(s) | Issue |
|---|---|---|
| `include/` | `sa_params.vh`: default `N`, `DATA_W`, `ACC_W`, `FRAC_W` | #2 |
| `pe/` | `mac.v`, `pe.v` | #6 |
| `array/` | `systolic_array.v` | #3 |
| `buffers/` | `input_skew_buffer.v`, `output_buffer.v` | #10 |
| `control/` | `sa_controller.v` | #7 |
| `top/` | `systolic_top.v` | #4 |
| `baseline/` | `seq_matmul.v`, single-MAC sequential baseline | Phase 2 |

Every module here has a self-checking testbench in [`tb/`](../tb/).
