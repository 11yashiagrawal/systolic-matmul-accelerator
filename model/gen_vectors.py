"""Generate golden test vectors (issues #14 and #72).

Writes the three vector sets of docs/spec.md section 9:

    <out>/          Phase 1 set (9.1): N x N cases with k_len = N
    <out>/kn/       K != N set (9.2): single runs with k_len from 1 to K_MAX,
                    in the hardware's N x K_MAX and K_MAX x N layout
    <out>/tiled/    tiled set (9.3): whole products C = A x B with A of size
                    M x K and B of size K x P, for the section 12 procedure

The Phase 1 files are:

    config.hex    line 0: N, line 1: number of cases (8 hex digits each)
    a.hex         cases x N x N lines, one element of A each (DATA_W / 4 digits)
    b.hex         same for B
    c.hex         same for the expected C (ACC_W / 4 digits)
    manifest.txt  N, seed and the index and name of every case, for people

Line ``case*N*N + r*N + c`` of a.hex, b.hex and c.hex holds element (r, c)
of that case. The kn/ and tiled/ formats are in ``write_kn_vectors`` and
``write_tiled_vectors``. Example (this is what ``make vectors`` runs):

    python model/gen_vectors.py --n 4 --random 100 --seed 1 --out sim/vectors

Each set draws from its own generator, seeded from ``--seed`` and the set,
so the Phase 1 files are byte-identical to those of Phase 1 and changing one
set never shifts the random cases of another.
"""

import argparse
import os
import sys

import numpy as np

from golden_model import (
    ACC_W,
    DATA_W,
    busy_cycles,
    ceil_div,
    chunk_lengths,
    compute_cycles,
    matmul,
    signed_range,
    simulate_output_stationary,
    simulate_tiled,
    tiled_matmul,
    to_hex,
)

K_MAX = 16          # SA_K_MAX in rtl/include/sa_params.vh
KN_RANDOM = 100     # random cases in the K != N set (spec 9.2)
TILED_RANDOM = 20   # random products in the tiled set (spec 9.3)

# Second entropy word of each set's generator. The Phase 1 set keeps the
# plain seed, so its files do not change.
KN_STREAM = 1
TILED_STREAM = 2


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


def kn_rng(seed):
    """Generator of the K != N set: independent of the Phase 1 stream."""
    return np.random.default_rng([seed, KN_STREAM])


def tiled_rng(seed):
    """Generator of the tiled set: independent of the other two streams."""
    return np.random.default_rng([seed, TILED_STREAM])


def write_hex_lines(path, values, width):
    """Write one two's complement hex value per line."""
    with open(path, "w", encoding="ascii") as f:
        for value in values:
            f.write(to_hex(value, width) + "\n")


def build_kn_cases(n, k_max, n_random, seed, data_w=DATA_W):
    """Return ``[(name, k_len, A, B), ...]`` for the K != N set (spec 9.2).

    A is N x K_MAX and B is K_MAX x N, the layout of the hardware's stores.
    Only the first k_len columns of A and rows of B take part in the run;
    the rest is random filler, so a design that reads past k_len fails.

    Directed cases come first: for each k_len in (1, N - 1, N + 1, K_MAX),
    skipping repeats and values outside 1 to K_MAX, the cases ``ones_k<k>``,
    ``max_negative_k<k>`` and ``random_k<k>``. Then ``n_random`` cases
    ``random_<i>`` with k_len uniform over 1 to K_MAX.
    """
    if k_max < n:
        raise ValueError(f"K_MAX must be at least N (spec section 3), got {k_max} < {n}")
    lo, hi = signed_range(data_w)
    rng = kn_rng(seed)

    def rand(shape):
        return rng.integers(lo, hi, size=shape, endpoint=True, dtype=np.int64)

    def with_filler(k_len, a_used, b_used):
        a, b = rand((n, k_max)), rand((k_max, n))
        a[:, :k_len] = a_used
        b[:k_len, :] = b_used
        return a, b

    k_lens = []
    for k_len in (1, n - 1, n + 1, k_max):
        if 1 <= k_len <= k_max and k_len not in k_lens:
            k_lens.append(k_len)

    cases = []
    for k_len in k_lens:
        cases.append((f"ones_k{k_len}", k_len,
                      *with_filler(k_len, 1, 1)))
        cases.append((f"max_negative_k{k_len}", k_len,
                      *with_filler(k_len, lo, lo)))
        cases.append((f"random_k{k_len}", k_len,
                      *with_filler(k_len, rand((n, k_len)), rand((k_len, n)))))
    for i in range(n_random):
        k_len = int(rng.integers(1, k_max, endpoint=True))
        cases.append((f"random_{i}", k_len, rand((n, k_max)), rand((k_max, n))))
    return cases


def write_kn_vectors(cases, n, k_max, seed, out_dir, data_w=DATA_W, acc_w=ACC_W):
    """Write the K != N set (spec 9.2) and return the expected C matrices.

        config.hex    N, the number of cases, K_MAX (8 hex digits each)
        klen.hex      each case's k_len (8 hex digits)
        a.hex         line case*N*K_MAX + r*K_MAX + k holds A[r][k]
        b.hex         line case*K_MAX*N + k*N + c holds B[k][c]
        c.hex         line case*N*N + r*N + c holds the expected C[r][c]
        manifest.txt  N, K_MAX, the seed, and each case's index, name, k_len

    Each expected C uses only k < k_len, and is cross-checked with the
    cycle-level model on the same N x k_len and k_len x N blocks.
    """
    expected = []
    for idx, (name, k_len, a, b) in enumerate(cases):
        a_run, b_run = a[:, :k_len], b[:k_len, :]
        c = matmul(a_run, b_run, data_w, acc_w)
        c_sim, steps = simulate_output_stationary(a_run, b_run, data_w, acc_w)
        if not np.array_equal(c, c_sim) or steps != compute_cycles(n, k_len):
            raise AssertionError(
                f"kn case {idx} ({name}): the cycle-level model disagrees with "
                f"the reference; fix the model before trusting these vectors")
        expected.append(c)

    os.makedirs(out_dir, exist_ok=True)
    write_hex_lines(os.path.join(out_dir, "config.hex"), [n, len(cases), k_max], 32)
    write_hex_lines(os.path.join(out_dir, "klen.hex"), [k for _, k, _, _ in cases], 32)
    write_hex_lines(os.path.join(out_dir, "a.hex"),
                    [v for _, _, a, _ in cases for v in a.reshape(-1)], data_w)
    write_hex_lines(os.path.join(out_dir, "b.hex"),
                    [v for _, _, _, b in cases for v in b.reshape(-1)], data_w)
    write_hex_lines(os.path.join(out_dir, "c.hex"),
                    [v for c in expected for v in c.reshape(-1)], acc_w)

    with open(os.path.join(out_dir, "manifest.txt"), "w", encoding="ascii") as f:
        f.write("# K != N vectors (docs/spec.md section 9.2)\n")
        f.write(f"N = {n}\nK_MAX = {k_max}\nDATA_W = {data_w}\nACC_W = {acc_w}\n")
        f.write(f"seed = {seed}\ncases = {len(cases)}\n")
        f.write("# A and B elements with k >= k_len are random filler\n")
        f.write("# a.hex and b.hex hold N*K_MAX lines per case, so a case starts\n")
        f.write("# on the same line of both (ab_first_line)\n")
        f.write("# index  k_len  T  busy  ab_first_line  c_first_line  name\n")
        for idx, (name, k_len, _, _) in enumerate(cases):
            f.write(f"{idx:5d}  {k_len:5d}  {compute_cycles(n, k_len):3d}  "
                    f"{busy_cycles(n, k_len):4d}  {idx * n * k_max:12d}  "
                    f"{idx * n * n:12d}  {name}\n")
    return expected


def build_tiled_products(n, k_max, n_random, seed, data_w=DATA_W):
    """Return ``[(name, A, B), ...]`` for the tiled set (spec 9.3).

    The directed products, in the spec's order, are ``exact``, ``pad_all``,
    ``chunks``, ``pad_chunks``, ``single`` and ``max_negative_long``; then
    ``n_random`` products with M and P uniform over 1 to 3N and K uniform
    over 1 to 3 K_MAX.
    """
    lo, hi = signed_range(data_w)
    rng = tiled_rng(seed)

    def rand(rows, cols):
        return rng.integers(lo, hi, size=(rows, cols), endpoint=True, dtype=np.int64)

    def random_product(name, m, k, p):
        return (name, rand(m, k), rand(k, p))

    long_k = 4 * k_max
    products = [
        random_product("exact", 2 * n, 2 * n, 2 * n),
        random_product("pad_all", n + 1, 2 * n - 1, n + 2),
        random_product("chunks", n, 5 * k_max // 2, n),
        random_product("pad_chunks", 2 * n + 1, 2 * k_max + 1, 2 * n - 1),
        random_product("single", 1, 1, 1),
        ("max_negative_long", np.full((n, long_k), lo, dtype=np.int64),
         np.full((long_k, n), lo, dtype=np.int64)),
    ]
    for i in range(n_random):
        m = int(rng.integers(1, 3 * n, endpoint=True))
        k = int(rng.integers(1, 3 * k_max, endpoint=True))
        p = int(rng.integers(1, 3 * n, endpoint=True))
        products.append(random_product(f"random_{i}", m, k, p))
    return products


def write_tiled_vectors(products, n, k_max, seed, out_dir, data_w=DATA_W, acc_w=ACC_W):
    """Write the tiled set (spec 9.3) and return the expected C matrices.

        config.hex    N, the number of products, K_MAX (8 hex digits each)
        dims.hex      M, K and P of each product, in that order (8 hex digits)
        a.hex         each product's A, row-major, products back to back
        b.hex         each product's B, row-major, back to back
        c.hex         each product's expected C, row-major, back to back
        manifest.txt  N, K_MAX, the seed, and each product's index, name,
                      dimensions, runs and first lines

    The expected C is ``matmul`` on the whole matrices. ``tiled_matmul``
    must reach the same C through the section 12 procedure, and the
    cycle-level model must reach every run's partial result.
    """
    expected = []
    for idx, (name, a, b) in enumerate(products):
        c = matmul(a, b, data_w, acc_w)
        c_tiled, runs = tiled_matmul(a, b, n, k_max, data_w, acc_w)
        sims = simulate_tiled(runs, data_w, acc_w)
        if not np.array_equal(c, c_tiled) or any(
                not np.array_equal(acc, run["partial"])
                or steps != compute_cycles(n, run["k_len"])
                for run, (acc, steps) in zip(runs, sims)):
            raise AssertionError(
                f"tiled product {idx} ({name}): the tiled or cycle-level model "
                f"disagrees with the reference; fix the model first")
        expected.append(c)

    os.makedirs(out_dir, exist_ok=True)
    write_hex_lines(os.path.join(out_dir, "config.hex"),
                    [n, len(products), k_max], 32)
    write_hex_lines(os.path.join(out_dir, "dims.hex"),
                    [d for _, a, b in products for d in (a.shape[0], a.shape[1], b.shape[1])], 32)
    write_hex_lines(os.path.join(out_dir, "a.hex"),
                    [v for _, a, _ in products for v in a.reshape(-1)], data_w)
    write_hex_lines(os.path.join(out_dir, "b.hex"),
                    [v for _, _, b in products for v in b.reshape(-1)], data_w)
    write_hex_lines(os.path.join(out_dir, "c.hex"),
                    [v for c in expected for v in c.reshape(-1)], acc_w)

    with open(os.path.join(out_dir, "manifest.txt"), "w", encoding="ascii") as f:
        f.write("# Tiled vectors (docs/spec.md section 9.3)\n")
        f.write(f"N = {n}\nK_MAX = {k_max}\nDATA_W = {data_w}\nACC_W = {acc_w}\n")
        f.write(f"seed = {seed}\nproducts = {len(products)}\n")
        f.write("# index    M    K    P  tiles  chunks  a_first  b_first  c_first  name\n")
        a_line = b_line = c_line = 0
        for idx, (name, a, b) in enumerate(products):
            m, k = a.shape
            p = b.shape[1]
            tiles = ceil_div(m, n) * ceil_div(p, n)
            chunks = len(chunk_lengths(k, k_max))
            f.write(f"{idx:7d}  {m:3d}  {k:3d}  {p:3d}  {tiles:5d}  {chunks:6d}  "
                    f"{a_line:7d}  {b_line:7d}  {c_line:7d}  {name}\n")
            a_line += m * k
            b_line += k * p
            c_line += m * p
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
    p.add_argument("--k-max", type=int, default=K_MAX,
                   help=f"largest k_len of one run, for kn/ and tiled/ (default {K_MAX})")
    p.add_argument("--kn-random", type=int, default=KN_RANDOM,
                   help=f"random cases in kn/ after the directed ones (default {KN_RANDOM})")
    p.add_argument("--tiled-random", type=int, default=TILED_RANDOM,
                   help=f"random products in tiled/ after the directed ones "
                        f"(default {TILED_RANDOM})")
    p.add_argument("--sets", nargs="+", choices=("phase1", "kn", "tiled"),
                   default=["phase1", "kn", "tiled"],
                   help="which vector sets to write (default: all three)")
    args = p.parse_args(argv)
    if args.n < 1:
        p.error("--n must be at least 1")
    if args.k_max < args.n:
        p.error(f"--k-max must be at least --n (spec section 3), got {args.k_max}")
    for flag, value in (("--random", args.random), ("--kn-random", args.kn_random),
                        ("--tiled-random", args.tiled_random)):
        if value < 0:
            p.error(f"{flag} must not be negative")
    for flag, width in (("--data-w", args.data_w), ("--acc-w", args.acc_w)):
        if width < 4 or width % 4:
            p.error(f"{flag} must be a positive multiple of 4, got {width}")
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        if "phase1" in args.sets:
            cases = build_cases(args.n, args.random, args.seed, args.data_w)
            write_vectors(cases, args.n, args.seed, args.out, args.data_w, args.acc_w)
            print(f"Wrote {len(cases)} cases ({len(cases) - args.random} directed, "
                  f"{args.random} random) for N = {args.n}, seed = {args.seed} "
                  f"to {args.out}")
        if "kn" in args.sets:
            out = os.path.join(args.out, "kn")
            cases = build_kn_cases(args.n, args.k_max, args.kn_random, args.seed,
                                   args.data_w)
            write_kn_vectors(cases, args.n, args.k_max, args.seed, out,
                             args.data_w, args.acc_w)
            print(f"Wrote {len(cases)} K != N cases ({len(cases) - args.kn_random} "
                  f"directed, {args.kn_random} random) for K_MAX = {args.k_max} to {out}")
        if "tiled" in args.sets:
            out = os.path.join(args.out, "tiled")
            products = build_tiled_products(args.n, args.k_max, args.tiled_random,
                                            args.seed, args.data_w)
            write_tiled_vectors(products, args.n, args.k_max, args.seed, out,
                                args.data_w, args.acc_w)
            print(f"Wrote {len(products)} tiled products "
                  f"({len(products) - args.tiled_random} directed, "
                  f"{args.tiled_random} random) to {out}")
    except (ValueError, OverflowError, AssertionError) as err:
        print(f"ERROR gen_vectors: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
