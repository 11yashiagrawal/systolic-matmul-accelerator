# Waveform captures (Phase 2)

GTKWave 3.4 captures, opened with the layouts in `sim/waves/` and `sim/waves/report.gtkwaverc` (the commands are at the top of each `.gtkw` file). The letters refer to the named markers in each capture. Both show golden case 5, the known product (A = 1…16, B = Aᵀ), on the sequential baseline `seq_matmul`.

| Capture | Caption |
|---|---|
| `seq_matmul.png` | The single MAC on the first two elements of C: `start` is taken (A), and over the next four cycles `k` steps 0 to 3 while the products 1, 4, 9 and 16 build the running sum 1, 5, 14, 30. C[0][0] = 30 is written as `col` moves on (B). The sum then restarts from the new product, 1·5 = 5, instead of adding to 30 (C), and C[0][1] = 70 is written four cycles later (D). Before A, `sum` still holds the last value of the previous run, which is ignored. |
| `seq_matmul_run.png` | One whole baseline run: `busy` stays high from `start` (A) to `done` (B) for 64 cycles, N²K for N = 4. `row` and `col` step through all 16 elements of C, four cycles each, and `cycle_count` reads 64 in DONE, against 12 for the array in `results/phase1/waveforms/systolic_top.png`. |
