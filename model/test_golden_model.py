"""Self-tests for the golden model and vector generator (issues #14, #72).

Run from the repository root:

    python -m unittest discover -s model -v

Expected values here are worked by hand or taken from docs/spec.md, never
from the model's own output.
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_vectors  # noqa: E402
from golden_model import (  # noqa: E402
    busy_cycles,
    chunk_lengths,
    compute_cycles,
    edge_inputs,
    from_hex,
    matmul,
    plan_tiles,
    simulate_output_stationary,
    simulate_tiled,
    tiled_matmul,
    to_hex,
)


class ReferenceModel(unittest.TestCase):
    def test_hand_worked_2x2(self):
        a = [[1, -2], [3, 4]]
        b = [[5, 6], [-7, 8]]
        # [1*5 + -2*-7, 1*6 + -2*8], [3*5 + 4*-7, 3*6 + 4*8]
        np.testing.assert_array_equal(matmul(a, b), [[19, -10], [-13, 50]])

    def test_spec_extremes_for_k4(self):
        lo = np.full((4, 4), -128)
        hi = np.full((4, 4), 127)
        self.assertTrue((matmul(lo, lo) == 65536).all())    # 4 * 16384
        self.assertTrue((matmul(lo, hi) == -65024).all())   # -4 * 16256

    def test_identity_returns_a(self):
        a = np.random.default_rng(7).integers(-128, 127, (4, 4), endpoint=True)
        np.testing.assert_array_equal(matmul(a, np.eye(4, dtype=int)), a)

    def test_rejects_out_of_range_operand(self):
        with self.assertRaises(ValueError):
            matmul([[128]], [[1]])
        with self.assertRaises(ValueError):
            matmul([[-129]], [[1]])

    def test_detects_accumulator_overflow(self):
        with self.assertRaises(OverflowError):
            matmul(np.full((1, 4), -128), np.full((4, 1), -128), acc_w=16)


class TimingModel(unittest.TestCase):
    def test_latency_formulas(self):
        self.assertEqual(compute_cycles(4), 10)
        self.assertEqual(busy_cycles(4), 12)
        self.assertEqual(compute_cycles(3), 7)

    def test_edge_inputs_match_table_7_2(self):
        # Encode A[i][k] as 10*i + k and B[k][j] as 50 + 10*k + j so every
        # element is distinct and its indices are readable.
        a = np.array([[10 * i + k for k in range(4)] for i in range(4)])
        b = np.array([[50 + 10 * k + j for j in range(4)] for k in range(4)])
        # Step 3: A03 A12 A21 A30 | B30 B21 B12 B03
        self.assertEqual(edge_inputs(a, b, 3), ([3, 12, 21, 30], [80, 71, 62, 53]))
        # Step 5: . . A23 A32 | . . B32 B23
        self.assertEqual(edge_inputs(a, b, 5), ([0, 0, 23, 32], [0, 0, 82, 73]))
        # Steps 7 to 9: all quiet
        for t in (7, 8, 9):
            self.assertEqual(edge_inputs(a, b, t), ([0] * 4, [0] * 4))

    def test_wavefront_at_step_3(self):
        # Spec 7.2: in step 3, PE (i, j) adds term k = 3 - i - j.
        a = np.array([[10 * i + k + 1 for k in range(4)] for i in range(4)])
        b = np.ones((4, 4), dtype=int)
        trace = []
        simulate_output_stationary(a, b, trace=trace)
        a_in = trace[3]["a_in"]
        for i in range(4):
            for j in range(4):
                k = 3 - i - j
                want = a[i, k] if k >= 0 else 0
                self.assertEqual(a_in[i, j], want, f"PE ({i}, {j})")

    def test_cycle_model_agrees_with_reference(self):
        rng = np.random.default_rng(2026)
        for n in (1, 2, 3, 4, 8):
            for _ in range(25):
                a = rng.integers(-128, 127, (n, n), endpoint=True)
                b = rng.integers(-128, 127, (n, n), endpoint=True)
                c, steps = simulate_output_stationary(a, b)
                self.assertEqual(steps, compute_cycles(n))
                np.testing.assert_array_equal(c, matmul(a, b))

    def test_one_step_short_is_wrong(self):
        # PE (N-1, N-1) adds its last term in step T - 1, so stopping one
        # step early must leave C[3][3] incomplete. This is why T is not 2N - 1.
        a = np.ones((4, 4), dtype=int)
        trace = []
        simulate_output_stationary(a, a, trace=trace)
        last = trace[-1]
        self.assertEqual(last["a_in"][3, 3] * last["b_in"][3, 3], 1)


class HexFormat(unittest.TestCase):
    def test_spec_examples(self):
        self.assertEqual(to_hex(-1, 8), "ff")
        self.assertEqual(to_hex(-65024, 32), "ffff0200")
        self.assertEqual(to_hex(127, 8), "7f")
        self.assertEqual(to_hex(-128, 8), "80")
        self.assertEqual(to_hex(4, 32), "00000004")

    def test_round_trip(self):
        for v in (-128, -1, 0, 1, 127):
            self.assertEqual(from_hex(to_hex(v, 8), 8), v)

    def test_rejects_values_that_do_not_fit(self):
        with self.assertRaises(ValueError):
            to_hex(128, 8)


class InnerLengthAndAccumulate(unittest.TestCase):
    """k_len != N and accumulate runs (issue #72, spec 7.1 and 7.6)."""

    def test_spec_cycle_table(self):
        # Spec 11.1 for N = 4: k_len = 4 and k_len = 16.
        self.assertEqual(compute_cycles(4, 4), 10)
        self.assertEqual(compute_cycles(4, 16), 22)
        self.assertEqual(busy_cycles(4, 4), 12)
        self.assertEqual(busy_cycles(4, 16), 24)
        self.assertEqual(busy_cycles(4, 4, accumulate=True), 11)
        self.assertEqual(busy_cycles(4, 16, accumulate=True), 23)

    def test_non_square_product_hand_worked(self):
        # A is 2 x 3 and B is 3 x 2: k_len = 3 on a 2 x 2 array.
        a = [[1, 2, 3], [4, 5, 6]]
        b = [[1, 0], [0, 1], [-1, 2]]
        # [1 - 3, 2 + 6], [4 - 6, 5 + 12]
        want = [[-2, 8], [-2, 17]]
        np.testing.assert_array_equal(matmul(a, b), want)
        c, steps = simulate_output_stationary(a, b)
        np.testing.assert_array_equal(c, want)
        self.assertEqual(steps, 3 + 2 * 2 - 2)

    def test_every_k_len_up_to_k_max(self):
        rng = np.random.default_rng(72)
        for k_len in range(1, 17):
            a = rng.integers(-128, 127, (4, k_len), endpoint=True)
            b = rng.integers(-128, 127, (k_len, 4), endpoint=True)
            c, steps = simulate_output_stationary(a, b)
            self.assertEqual(steps, compute_cycles(4, k_len), f"k_len = {k_len}")
            np.testing.assert_array_equal(c, a @ b, f"k_len = {k_len}")

    def test_accumulate_adds_onto_old_c(self):
        a = np.ones((2, 1), dtype=int)
        b = np.ones((1, 2), dtype=int)
        old_c = [[10, -20], [30, 40]]
        c, _ = simulate_output_stationary(a, b, acc_init=old_c)
        np.testing.assert_array_equal(c, [[11, -19], [31, 41]])

    def test_accumulate_rejects_wrong_shape(self):
        with self.assertRaises(ValueError):
            simulate_output_stationary(np.ones((2, 2), dtype=int),
                                       np.ones((2, 2), dtype=int),
                                       acc_init=np.zeros((3, 3)))


class Tiling(unittest.TestCase):
    """Host-driven tiling of C = A x B (issue #72, spec section 12)."""

    # A 3 x 3 product on a 2 x 2 array with K_MAX = 2, worked by hand below.
    A = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
    B = [[1, 0, -1], [2, 1, 0], [0, 3, 1]]
    C = [[5, 11, 2], [14, 23, 2], [23, 35, 2]]

    def test_chunk_lengths(self):
        self.assertEqual(chunk_lengths(40, 16), [16, 16, 8])   # spec 9.3 'chunks'
        self.assertEqual(chunk_lengths(33, 16), [16, 16, 1])   # 'pad_chunks'
        self.assertEqual(chunk_lengths(64, 16), [16, 16, 16, 16])
        self.assertEqual(chunk_lengths(3, 16), [3])
        with self.assertRaises(ValueError):
            chunk_lengths(0, 16)
        with self.assertRaises(ValueError):
            chunk_lengths(4, 0)

    def test_plan_order_and_accumulate_flags(self):
        # M = 5, P = 3 on N = 4: 2 x 1 tiles; K = 40: chunks 16, 16, 8.
        runs = plan_tiles(5, 40, 3, 4, 16)
        self.assertEqual([(r["tile_row"], r["tile_col"], r["chunk"]) for r in runs],
                         [(0, 0, 0), (0, 0, 1), (0, 0, 2),
                          (1, 0, 0), (1, 0, 1), (1, 0, 2)])
        self.assertEqual([r["k_start"] for r in runs], [0, 16, 32, 0, 16, 32])
        self.assertEqual([r["k_len"] for r in runs], [16, 16, 8, 16, 16, 8])
        self.assertEqual([r["accumulate"] for r in runs],
                         [False, True, True, False, True, True])

    def test_hand_worked_3x3_on_2x2(self):
        c, runs = tiled_matmul(self.A, self.B, n=2, k_max=2)
        np.testing.assert_array_equal(c, self.C)
        self.assertEqual(len(runs), 8)  # 2 x 2 tiles, chunks of 2 and 1

        # Tile (0, 0), chunk 0: [[1, 2], [4, 5]] x [[1, 0], [2, 1]]
        np.testing.assert_array_equal(runs[0]["partial"], [[5, 2], [14, 5]])
        # Chunk 1 adds [3, 6]^T x [0, 3] = [[0, 9], [0, 18]]
        np.testing.assert_array_equal(runs[1]["partial"], [[5, 11], [14, 23]])

        # Tile (1, 1) is the corner: only A[2] and B[:, 2] are real, the rest
        # is zero padding. Chunk 0: 7 * -1 + 8 * 0 = -7.
        corner = runs[6:]
        self.assertEqual((corner[0]["tile_row"], corner[0]["tile_col"]), (1, 1))
        np.testing.assert_array_equal(corner[0]["a"], [[7, 8], [0, 0]])
        np.testing.assert_array_equal(corner[0]["b"], [[-1, 0], [0, 0]])
        np.testing.assert_array_equal(corner[0]["partial"], [[-7, 0], [0, 0]])
        # Chunk 1 adds 9 * 1 = 9, so C[2][2] = 2.
        np.testing.assert_array_equal(corner[1]["a"], [[9], [0]])
        np.testing.assert_array_equal(corner[1]["partial"], [[2, 0], [0, 0]])

    def test_random_shapes_match_numpy(self):
        rng = np.random.default_rng(2026)
        for n in (2, 3, 4):
            for k_max in (n, 2 * n, 16):
                for _ in range(10):
                    m, k, p = (int(x) for x in rng.integers(1, 20, size=3))
                    a = rng.integers(-128, 127, (m, k), endpoint=True)
                    b = rng.integers(-128, 127, (k, p), endpoint=True)
                    c, runs = tiled_matmul(a, b, n, k_max)
                    np.testing.assert_array_equal(c, a @ b)
                    for r in runs:
                        self.assertTrue(1 <= r["k_len"] <= k_max)
                        self.assertEqual(r["a"].shape, (n, r["k_len"]))
                        self.assertEqual(r["b"].shape, (r["k_len"], n))

    def test_cycle_model_reaches_every_partial(self):
        # The cycle model, carrying the accumulators across accumulate runs,
        # must hit each expected partial after exactly k_len + 2N - 2 steps.
        rng = np.random.default_rng(5)
        for n, k_max, (m, k, p) in ((2, 2, (3, 3, 3)), (4, 16, (9, 33, 7)),
                                    (4, 16, (4, 40, 4)), (3, 3, (4, 7, 2))):
            a = rng.integers(-128, 127, (m, k), endpoint=True)
            b = rng.integers(-128, 127, (k, p), endpoint=True)
            _, runs = tiled_matmul(a, b, n, k_max)
            for run, (acc, steps) in zip(runs, simulate_tiled(runs)):
                np.testing.assert_array_equal(acc, run["partial"])
                self.assertEqual(steps, compute_cycles(n, run["k_len"]))

    def test_overflow_across_chunks_is_caught(self):
        # Each chunk adds (-128)^2 = 16384; the second pushes a 16-bit
        # accumulator past 32767, although no single chunk overflows.
        a = np.full((1, 2), -128)
        b = np.full((2, 1), -128)
        with self.assertRaises(OverflowError):
            tiled_matmul(a, b, n=1, k_max=1, acc_w=16)


class Generator(unittest.TestCase):
    def generate(self, n=4, n_random=5, seed=1):
        out = tempfile.mkdtemp()
        rc = gen_vectors.main(["--n", str(n), "--random", str(n_random),
                               "--seed", str(seed), "--out", out])
        self.assertEqual(rc, 0)
        return out

    @staticmethod
    def read(out, name):
        with open(os.path.join(out, name), encoding="ascii") as f:
            return f.read().split()

    def test_file_shapes_and_config(self):
        out = self.generate(n=4, n_random=5)
        cases = 6 + 5
        self.assertEqual(self.read(out, "config.hex"), ["00000004", "0000000b"])
        for name, digits in (("a.hex", 2), ("b.hex", 2), ("c.hex", 8)):
            lines = self.read(out, name)
            self.assertEqual(len(lines), cases * 16, name)
            self.assertTrue(all(len(x) == digits for x in lines), name)

    def test_directed_cases(self):
        out = self.generate(n=4, n_random=0)
        a = [from_hex(x, 8) for x in self.read(out, "a.hex")]
        c = [from_hex(x, 32) for x in self.read(out, "c.hex")]

        def case(values, idx):
            return np.array(values[idx * 16:(idx + 1) * 16]).reshape(4, 4)

        np.testing.assert_array_equal(case(c, 0), case(a, 0))  # identity
        self.assertTrue((case(c, 1) == 0).all())               # zero
        self.assertTrue((case(c, 2) == 4).all())               # ones
        self.assertTrue((case(c, 3) == 65536).all())           # max_negative
        self.assertTrue((case(c, 4) == -65024).all())          # max_mixed
        # known: A = 1..16 row-major, B = A transposed, so C[0][0] is
        # 1 + 4 + 9 + 16 = 30 and C[3][3] is 13^2 + 14^2 + 15^2 + 16^2 = 846.
        self.assertEqual(case(c, 5)[0, 0], 30)
        self.assertEqual(case(c, 5)[3, 3], 846)

    def test_same_seed_same_files(self):
        first, second = self.generate(seed=9), self.generate(seed=9)
        for name in ("a.hex", "b.hex", "c.hex"):
            self.assertEqual(self.read(first, name), self.read(second, name))

    def test_other_n(self):
        out = self.generate(n=3, n_random=2)
        self.assertEqual(self.read(out, "config.hex")[0], "00000003")
        self.assertEqual(len(self.read(out, "c.hex")), 8 * 9)


class KnVectors(unittest.TestCase):
    """The K != N set, sim/vectors/kn/ (spec 9.2)."""

    @classmethod
    def setUpClass(cls):
        cls.out = tempfile.mkdtemp()
        rc = gen_vectors.main(["--n", "4", "--k-max", "16", "--kn-random", "5",
                               "--seed", "1", "--sets", "kn", "--out", cls.out])
        assert rc == 0
        cls.dir = os.path.join(cls.out, "kn")

    def read(self, name, width=None):
        with open(os.path.join(self.dir, name), encoding="ascii") as f:
            lines = f.read().split()
        return lines if width is None else [from_hex(x, width) for x in lines]

    def test_only_requested_set_is_written(self):
        self.assertFalse(os.path.exists(os.path.join(self.out, "a.hex")))

    def test_config_and_file_lengths(self):
        cases = 12 + 5  # 4 k_lens x 3 directed cases, then 5 random
        self.assertEqual(self.read("config.hex"), ["00000004", "00000011", "00000010"])
        self.assertEqual(len(self.read("klen.hex")), cases)
        self.assertEqual(len(self.read("a.hex")), cases * 4 * 16)
        self.assertEqual(len(self.read("b.hex")), cases * 16 * 4)
        self.assertEqual(len(self.read("c.hex")), cases * 4 * 4)

    def test_directed_k_lens_and_values(self):
        k_lens = self.read("klen.hex", 32)
        # (1, N - 1, N + 1, K_MAX) = (1, 3, 5, 16), three cases each
        self.assertEqual(k_lens[:12], [1] * 3 + [3] * 3 + [5] * 3 + [16] * 3)
        c = self.read("c.hex", 32)
        for case, k_len in enumerate(k_lens[:12]):
            block = c[case * 16:(case + 1) * 16]
            if case % 3 == 0:       # ones_k: every element is k_len
                self.assertEqual(set(block), {k_len})
            elif case % 3 == 1:     # max_negative_k: k_len * 16384
                self.assertEqual(set(block), {k_len * 16384})

    def test_filler_beyond_k_len_is_not_zero(self):
        # Case 0 is ones_k1: column 0 of A is 1, columns 1 to 15 are filler.
        a = np.array(self.read("a.hex", 8)[:64]).reshape(4, 16)
        self.assertTrue((a[:, 0] == 1).all())
        self.assertTrue((a[:, 1:] != 0).any())

    def test_expected_c_uses_only_k_below_k_len(self):
        k_lens = self.read("klen.hex", 32)
        a = np.array(self.read("a.hex", 8)).reshape(-1, 4, 16)
        b = np.array(self.read("b.hex", 8)).reshape(-1, 16, 4)
        c = np.array(self.read("c.hex", 32)).reshape(-1, 4, 4)
        for case, k_len in enumerate(k_lens):
            np.testing.assert_array_equal(
                c[case], a[case][:, :k_len] @ b[case][:k_len, :], f"case {case}")


class TiledVectors(unittest.TestCase):
    """The tiled set, sim/vectors/tiled/ (spec 9.3)."""

    @classmethod
    def setUpClass(cls):
        cls.out = tempfile.mkdtemp()
        rc = gen_vectors.main(["--n", "4", "--k-max", "16", "--tiled-random", "3",
                               "--seed", "1", "--sets", "tiled", "--out", cls.out])
        assert rc == 0
        cls.dir = os.path.join(cls.out, "tiled")

    def read(self, name, width):
        with open(os.path.join(self.dir, name), encoding="ascii") as f:
            return [from_hex(x, width) for x in f.read().split()]

    def products(self):
        dims = self.read("dims.hex", 32)
        a, b, c = self.read("a.hex", 8), self.read("b.hex", 8), self.read("c.hex", 32)
        out, ia, ib, ic = [], 0, 0, 0
        for i in range(0, len(dims), 3):
            m, k, p = dims[i:i + 3]
            out.append((np.array(a[ia:ia + m * k]).reshape(m, k),
                        np.array(b[ib:ib + k * p]).reshape(k, p),
                        np.array(c[ic:ic + m * p]).reshape(m, p)))
            ia, ib, ic = ia + m * k, ib + k * p, ic + m * p
        self.assertEqual((ia, ib, ic), (len(a), len(b), len(c)))
        return out

    def test_config_and_directed_dimensions(self):
        self.assertEqual(self.read("config.hex", 32), [4, 6 + 3, 16])
        dims = self.read("dims.hex", 32)
        # Spec 9.3 for N = 4, K_MAX = 16
        self.assertEqual(dims[:18], [8, 8, 8, 5, 7, 6, 4, 40, 4,
                                     9, 33, 7, 1, 1, 1, 4, 64, 4])
        for i in range(18, len(dims), 3):
            m, k, p = dims[i:i + 3]
            self.assertTrue(1 <= m <= 12 and 1 <= k <= 48 and 1 <= p <= 12)

    def test_max_negative_long_does_not_overflow(self):
        a, b, c = self.products()[5]
        self.assertTrue((a == -128).all() and (b == -128).all())
        self.assertTrue((c == 1048576).all())   # 64 * 16384

    def test_every_product_matches_numpy(self):
        for idx, (a, b, c) in enumerate(self.products()):
            np.testing.assert_array_equal(c, a @ b, f"product {idx}")


class VectorSetsAreIndependent(unittest.TestCase):
    def test_phase1_files_do_not_depend_on_other_sets(self):
        only, full = tempfile.mkdtemp(), tempfile.mkdtemp()
        gen_vectors.main(["--random", "3", "--sets", "phase1", "--out", only])
        gen_vectors.main(["--random", "3", "--kn-random", "7", "--out", full])
        for name in ("config.hex", "a.hex", "b.hex", "c.hex", "manifest.txt"):
            with open(os.path.join(only, name)) as f1, open(os.path.join(full, name)) as f2:
                self.assertEqual(f1.read(), f2.read(), name)

    def test_k_max_below_n_is_rejected(self):
        with self.assertRaises(SystemExit), \
                contextlib.redirect_stderr(io.StringIO()):  # argparse's usage text
            gen_vectors.parse_args(["--n", "4", "--k-max", "3"])


if __name__ == "__main__":
    unittest.main()
