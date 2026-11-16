"""Generate golden test vectors for tb_systolic_top (issue #14).

Writes the files described in docs/spec.md section 9:

    config.hex    line 0: N, line 1: number of cases (8 hex digits each)
    a.hex         cases x N x N lines, one element of A each (DATA_W / 4 digits)
    b.hex         same for B
    c.hex         same for the expected C (ACC_W / 4 digits)
    manifest.txt  N, seed and the index and name of every case, for people

Line ``case*N*N + r*N + c`` of a.hex, b.hex and c.hex holds element (r, c)
of that case. Example (this is what ``make vectors`` runs):

    python model/gen_vectors.py --n 4 --random 100 --seed 1 --out sim/vectors
"""

import argparse
import os
import sys

import numpy as np

from golden_model import (
    ACC_W,
    DATA_W,
    busy_cycles,
    compute_cycles,
    matmul,
    signed_range,
    simulate_output_stationary,
    to_hex,
)


def build_cases(n, n_random, seed, data_w=DATA_W):
    """Return ``[(name, A, B), ...]``: the six directed cases of spec table 9,
    in order, followed by ``n_random`` random cases.

    One generator, seeded once, supplies every random value, including the
    random A of ``identity`` and ``zero``. The same seed therefore always
    reproduces the same file, but adding or reordering a directed case
    changes every random case after it.
    """
    lo, hi = signed_range(data_w)
    rng = np.random.default_rng(seed)

    def rand():
        return rng.integers(lo, hi, size=(n, n), endpoint=True, dtype=np.int64)

    def full(value):
        return np.full((n, n), value, dtype=np.int64)

    if n * n > hi:
        raise ValueError(
            f"the 'known' case uses the values 1 to N^2 = {n * n}, "
            f"which do not fit in DATA_W = {data_w} (max {hi})")
    known = np.arange(1, n * n + 1, dtype=np.int64).reshape(n, n)

    cases = [
        ("identity", rand(), np.eye(n, dtype=np.int64)),
        ("zero", rand(), full(0)),
        ("ones", full(1), full(1)),
        ("max_negative", full(lo), full(lo)),
        ("max_mixed", full(lo), full(hi)),
        ("known", known, known.T.copy()),
    ]
    for i in range(n_random):
        cases.append((f"random_{i}", rand(), rand()))
    return cases


def write_vectors(cases, n, seed, out_dir, data_w=DATA_W, acc_w=ACC_W):
    """Compute every expected C, cross-check it with the cycle-level model and
    write the files. Returns the list of expected C matrices."""
    expected = []
    for idx, (name, a, b) in enumerate(cases):
        c = matmul(a, b, data_w, acc_w)
        c_sim, steps = simulate_output_stationary(a, b, data_w, acc_w)
        if not np.array_equal(c, c_sim) or steps != compute_cycles(n):
            raise AssertionError(
                f"case {idx} ({name}): the cycle-level model disagrees with "
                f"the reference; fix the model before trusting these vectors")
        expected.append(c)

    os.makedirs(out_dir, exist_ok=True)

    def write_matrices(filename, matrices, width):
        with open(os.path.join(out_dir, filename), "w", encoding="ascii") as f:
            for m in matrices:
                for value in np.asarray(m).reshape(-1):  # row-major: r*N + c
                    f.write(to_hex(value, width) + "\n")

    with open(os.path.join(out_dir, "config.hex"), "w", encoding="ascii") as f:
        f.write(to_hex(n, 32) + "\n")
        f.write(to_hex(len(cases), 32) + "\n")
    write_matrices("a.hex", [a for _, a, _ in cases], data_w)
    write_matrices("b.hex", [b for _, _, b in cases], data_w)
    write_matrices("c.hex", expected, acc_w)

    with open(os.path.join(out_dir, "manifest.txt"), "w", encoding="ascii") as f:
        f.write("# Golden vectors for tb_systolic_top (docs/spec.md section 9)\n")
        f.write(f"N = {n}\nK = {n}\nDATA_W = {data_w}\nACC_W = {acc_w}\n")
        f.write(f"seed = {seed}\ncases = {len(cases)}\n")
        f.write(f"compute_cycles_T = {compute_cycles(n)}\n")
        f.write(f"busy_cycles = {busy_cycles(n)}\n")
        f.write("# index  first_line  name\n")
        for idx, (name, _, _) in enumerate(cases):
            f.write(f"{idx:5d}  {idx * n * n:10d}  {name}\n")

    return expected


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--n", type=int, default=4, help="array size N (default 4)")
    p.add_argument("--random", type=int, default=100,
                   help="number of random cases after the directed ones (default 100)")
    p.add_argument("--seed", type=int, default=1, help="NumPy seed (default 1)")
    p.add_argument("--out", default="sim/vectors", help="output directory")
    p.add_argument("--data-w", type=int, default=DATA_W, help="operand width (default 8)")
    p.add_argument("--acc-w", type=int, default=ACC_W, help="accumulator width (default 32)")
    args = p.parse_args(argv)
    if args.n < 1:
        p.error("--n must be at least 1")
    if args.random < 0:
        p.error("--random must not be negative")
    for flag, width in (("--data-w", args.data_w), ("--acc-w", args.acc_w)):
        if width < 4 or width % 4:
            p.error(f"{flag} must be a positive multiple of 4, got {width}")
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        cases = build_cases(args.n, args.random, args.seed, args.data_w)
        write_vectors(cases, args.n, args.seed, args.out, args.data_w, args.acc_w)
    except (ValueError, OverflowError, AssertionError) as err:
        print(f"ERROR gen_vectors: {err}", file=sys.stderr)
        return 1
    print(f"Wrote {len(cases)} cases ({len(cases) - args.random} directed, "
          f"{args.random} random) for N = {args.n}, seed = {args.seed} "
          f"to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
