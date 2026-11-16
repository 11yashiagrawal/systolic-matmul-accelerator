"""Self-tests for the golden model and vector generator (issue #14).

Run from the repository root:

    python -m unittest discover -s model -v

Expected values here are worked by hand or taken from docs/spec.md, never
from the model's own output.
"""

import os
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_vectors  # noqa: E402
from golden_model import (  # noqa: E402
    busy_cycles,
    compute_cycles,
    edge_inputs,
    from_hex,
    matmul,
    simulate_output_stationary,
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


if __name__ == "__main__":
    unittest.main()
