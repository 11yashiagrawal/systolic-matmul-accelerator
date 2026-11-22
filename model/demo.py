"""Live demonstration: one product on the systolic array and on the baseline (issue #70).

Multiplies an M x K matrix A by a K x P matrix B of any size in simulation, on
systolic_top (tiled into N x N output tiles and chunks of at most K_MAX, with
accumulate runs) and on seq_matmul, through the same host ports. Prints A, B
and C, checks both results against NumPy, and prints both designs' cycle
counts and the speed-up. Exits with status 1 if either result is wrong.

Run from the repository root (or with make demo):

    python model/demo.py                          # random 8x20x8 product, seed 1
    python model/demo.py --m 9 --k 33 --p 7 --seed 4
    python model/demo.py --a my_a.txt --b my_b.txt  # your own matrices
    python model/demo.py --waves                  # also open the last tile's waveform

A matrix file holds one row per line, integers from -128 to 127 separated by
spaces or commas. Lines starting with # are ignored.
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import ACC_W, DATA_W, matmul, to_hex  # noqa: E402

N = 4            # SA_N
K_MAX = 16       # SA_K_MAX
OUT = os.path.join("build", "demo")
MAX_AB = 65536   # operand storage of tb/demo.v
MAX_C = 4096


def load_matrix(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                rows.append([int(x) for x in re.split(r"[,\s]+", line) if x])
    if not rows or any(len(r) != len(rows[0]) for r in rows):
        raise ValueError(f"{path}: every row must have the same number of values")
    return np.array(rows, dtype=np.int64)


def check_dims(m, k, p):
    if min(m, k, p) < 1:
        raise ValueError("M, K and P must be at least 1")
    if m * k > MAX_AB or k * p > MAX_AB or m * p > MAX_C:
        raise ValueError(f"{m}x{k}x{p} is too large for the demo host "
                         f"(M*K and K*P at most {MAX_AB}, M*P at most {MAX_C})")


def write_hex(path, values, width):
    with open(path, "w", encoding="ascii") as f:
        for v in values:
            f.write(to_hex(int(v), width) + "\n")


def read_c(path, m, p):
    vals = []
    with open(path, encoding="ascii") as f:
        for line in f:
            v = int(line.strip(), 16)
            vals.append(v - (1 << ACC_W) if v >= 1 << (ACC_W - 1) else v)
    return np.array(vals, dtype=np.int64).reshape(m, p)


def simulate(design, waves):
    """Compile tb/demo.v for one design, run it, and return its DEMO line."""
    rtl = sorted(glob.glob("rtl/**/*.v", recursive=True))
    incs = sorted({os.path.dirname(f) for f in glob.glob("rtl/**/*.v*", recursive=True)}
                  | {"rtl/include", "tb/common"})
    vvp = os.path.join(OUT, f"{design}.vvp")
    cmd = ["iverilog", "-g2005", "-Wall", "-s", "demo_tb", "-o", vvp]
    cmd += [f"-I{d}" for d in incs]
    if design == "baseline":
        cmd.append("-DBASELINE")
    cmd += rtl + ["tb/demo.v"]
    subprocess.run(cmd, check=True, capture_output=True, text=True)
    run = subprocess.run(["vvp", "-n", vvp] + (["+waves"] if waves else []),
                         check=True, capture_output=True, text=True)
    line = next((l for l in run.stdout.splitlines() if l.startswith(f"DEMO {design} ")), None)
    if line is None:
        raise RuntimeError(f"{design} run printed no DEMO line:\n{run.stdout}{run.stderr}")
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}


def show(name, mat):
    text = np.array2string(mat, threshold=200, edgeitems=4, max_line_width=110)
    print(f"{name} ({mat.shape[0]} x {mat.shape[1]}):\n{text}\n")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--m", type=int, default=8, help="rows of A and C (default 8)")
    ap.add_argument("--k", type=int, default=20, help="columns of A, rows of B (default 20)")
    ap.add_argument("--p", type=int, default=8, help="columns of B and C (default 8)")
    ap.add_argument("--seed", type=int, default=1, help="seed of the random matrices")
    ap.add_argument("--a", help="file with your own A (overrides --m, --k)")
    ap.add_argument("--b", help="file with your own B (overrides --k, --p)")
    ap.add_argument("--waves", action="store_true",
                    help="dump the last tile of the array run and open it")
    args = ap.parse_args(argv)
    t_start = time.time()

    try:
        if args.a or args.b:
            if not (args.a and args.b):
                raise ValueError("give both --a and --b")
            a, b = load_matrix(args.a), load_matrix(args.b)
            if a.shape[1] != b.shape[0]:
                raise ValueError(f"A is {a.shape[0]}x{a.shape[1]} but B is "
                                 f"{b.shape[0]}x{b.shape[1]}: the inner sizes differ")
        else:
            rng = np.random.default_rng(args.seed)
            a = rng.integers(-128, 128, size=(args.m, args.k), dtype=np.int64)
            b = rng.integers(-128, 128, size=(args.k, args.p), dtype=np.int64)
        m, k = a.shape
        p = b.shape[1]
        check_dims(m, k, p)
        c_ref = np.array(matmul(a, b), dtype=np.int64)   # range-checks A, B and C
    except (OSError, ValueError) as e:
        print(f"FAIL demo: {e}", file=sys.stderr)
        return 1

    os.makedirs(OUT, exist_ok=True)
    write_hex(os.path.join(OUT, "dims.hex"), [m, k, p], 32)
    write_hex(os.path.join(OUT, "a.hex"), a.flatten(), DATA_W)
    write_hex(os.path.join(OUT, "b.hex"), b.flatten(), DATA_W)

    tiles = -(-m // N) * -(-p // N)
    chunks = -(-k // K_MAX)
    print(f"C = A x B with A {m}x{k} and B {k}x{p}, on a {N}x{N} array with K_MAX = {K_MAX}: "
          f"{tiles} output tile(s) x {chunks} chunk(s) = {tiles * chunks} run(s)\n")
    show("A", a)
    show("B", b)

    results, ok = {}, True
    try:
        for design in ("array", "baseline"):
            results[design] = simulate(design, args.waves and design == "array")
            c = read_c(os.path.join(OUT, f"c_{design}.hex"), m, p)
            match = np.array_equal(c, c_ref)
            ok &= match
            results[design]["match"] = match
            if design == "array":
                show("C from systolic_top", c)
    except (subprocess.CalledProcessError, RuntimeError, FileNotFoundError) as e:
        detail = getattr(e, "stderr", "") or getattr(e, "stdout", "") or ""
        print(f"FAIL demo: simulation failed: {e}\n{detail}", file=sys.stderr)
        return 1

    print("NumPy check (A @ B):")
    for design, name in (("array", "systolic_top"), ("baseline", "seq_matmul")):
        print(f"  {name:13s} {'matches' if results[design]['match'] else 'DOES NOT MATCH'}")
    ra, rb = results["array"], results["baseline"]
    print("\nCycles               busy     total (load + start + busy + readout)")
    print(f"  systolic_top {ra['busy']:10d} {ra['host']:9d}")
    print(f"  seq_matmul   {rb['busy']:10d} {rb['host']:9d}")
    print(f"  speed-up     {rb['busy'] / ra['busy']:9.2f}x {rb['host'] / ra['host']:8.2f}x\n")

    if args.waves:
        vcd = os.path.join(OUT, "array.vcd")
        viewer = shutil.which("gtkwave") or shutil.which("surfer")
        if viewer:
            subprocess.Popen([viewer, vcd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"Opened the last tile's waveform, {vcd}, in {os.path.basename(viewer)}.")
        else:
            print(f"Waveform of the last tile: {vcd} (no GTKWave or Surfer found to open it).")

    elapsed = time.time() - t_start
    if ok:
        print(f"PASS demo: {m}x{k}x{p} correct on both designs, busy-cycle speed-up "
              f"{rb['busy'] / ra['busy']:.2f}x, end to end {rb['host'] / ra['host']:.2f}x "
              f"({elapsed:.1f} s)")
        return 0
    print(f"FAIL demo: a result does not match NumPy ({elapsed:.1f} s)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
