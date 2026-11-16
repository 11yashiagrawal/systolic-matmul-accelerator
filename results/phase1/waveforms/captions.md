# Waveform captures

GTKWave 3.4 captures, opened with the layouts in `sim/waves/` and `sim/waves/report.gtkwaverc` (the commands are at the top of each `.gtkw` file). The letters refer to the named markers in each capture.

| Capture | Caption |
|---|---|
| `pe.png` | One PE (`tb_pe`): each operand leaves on `a_out`/`b_out` one enabled cycle after it arrives (A) and holds while `en` is low (B); `acc` sums 1·5 + 2·6 + 3·7 + 4·8 = 70 over K = 4 steps (C), and −128 × −128 gives 16,384 (D). |
| `systolic_array.png` | The 4 × 4 array on the known product (A = 1…16, B = Aᵀ): row i of A and column j of B enter i and j cycles late, so A[1][k] meets B[k][2] at PE (1, 2) from marker B on and gives C[1][2] = 278 (C), and PE (3, 3) finishes C[3][3] = 846 in the last step, T − 1 = 9 (D); values during CLEAR are random and ignored. |
| `systolic_top.png` | The top level on golden case 5: `start` is taken (A), `busy` stays high for one CLEAR, ten COMPUTE steps and one CAPTURE (B), `done` rises with `cycle_count` = 12 (C), and C is then read one element per cycle, with C[1][2] = 278 at address 6 (D). |
