# Waveform captures (Phase 2)

GTKWave 3.4 captures, opened with the layouts in `sim/waves/` and `sim/waves/report.gtkwaverc` (the commands are at the top of each `.gtkw` file). The letters refer to the named markers in each capture. Times are in the VCD that `make sim-seq_matmul` or `make sim-systolic_top` writes to `build/`.

## Sequential baseline (`tb_seq_matmul`)

Both show golden case 5, the known product (A = 1…16, B = Aᵀ), with `k_len` = 4.

| Capture | Caption |
|---|---|
| `seq_matmul.png` | The single MAC on the first two elements of C: `start` is taken (A), and over the next four cycles `k` steps 0 to 3 while the products 1, 4, 9 and 16 build the running sum 1, 5, 14, 30. C[0][0] = 30 is written as `col` moves on (B). The sum then restarts from the new product, 1·5 = 5, instead of adding to 30 (C), and C[0][1] = 70 is written four cycles later (D). Before A, `sum` still holds the last value of the previous run, which is ignored. |
| `seq_matmul_run.png` | One whole baseline run: `busy` stays high from `start` (A) to `done` (B) for 64 cycles, N²·`k_len` for N = `k_len` = 4. `row` and `col` step through all 16 elements of C, four cycles each, and `cycle_count` reads 64 in DONE, against 12 for the array in `results/phase1/waveforms/systolic_top.png`. |

## Accelerator with a run-time inner length (`tb_systolic_top`)

| Capture | Caption |
|---|---|
| `systolic_top_klen.png` | A run with `k_len` = 5, K ≠ N case 6 (`ones_k5`): A and B are all 1 for k < 5, and random filler is stored past k = 5. `start` is taken with `k_len` = 5, which the controller copies into `run_k_len` (A). After one CLEAR cycle, COMPUTE runs from step 0 (B) to step 10 (C), so T = `k_len` + 2N − 2 = 11 steps instead of the 10 of a `k_len` = 4 run. PE (0,0) adds its five products in steps 0 to 4 (`acc` 1 to 5), and PE (3,3), the last to start, adds its five in steps 6 to 10. After CAPTURE, `done` rises with `cycle_count` = `k_len` + 2N = 13 (D). The filler never reaches the array, so every element of C is 5. |
| `systolic_top_accumulate.png` | The second and third chunks of tiled product 2 (4×40×4: one tile, chunks of 16, 16 and 8). Before A, the first chunk has finished as a normal run (`cycle_count` = 24) and the host has written the second chunk's operands. That start has `accumulate` high (A), so `state` goes from DONE (4) straight to COMPUTE (2): there is no CLEAR, `clear` stays low, and PE (0,0) carries on from its partial sum of −28,112 to −53,993. `done` rises with `cycle_count` = 16 + 2N − 1 = 23 (B). The host then writes the third chunk's operands (`a_we` high for N·`k_len` = 32 cycles) and starts it with `k_len` = 8 and `accumulate` high (C). It ends with `cycle_count` = 8 + 2N − 1 = 15, and PE (0,0) holds −83,993, the expected C[0][0] of the whole product (D). |
