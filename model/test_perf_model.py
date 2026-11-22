"""Self-tests for the performance model (issue #73).

Run from the repository root:

    python -m unittest discover -s model -v

Expected values come from docs/spec.md section 11 or are worked by hand
here, never from the model's own output.
"""

import io
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import perf_model as pm  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class OneRun(unittest.TestCase):
    """Spec 11.1, N = 4."""

    def test_spec_table_k4_and_k16(self):
        self.assertEqual(pm.array_busy(4, 4), 12)
        self.assertEqual(pm.array_busy(4, 16), 24)
        self.assertEqual(pm.array_busy(4, 4, accumulate=True), 11)
        self.assertEqual(pm.array_busy(4, 16, accumulate=True), 23)
        self.assertEqual(pm.baseline_busy(4, 4), 64)
        self.assertEqual(pm.baseline_busy(4, 16), 256)
        self.assertEqual(pm.macs(4, 16), 256)
        self.assertAlmostEqual(pm.utilization(4, 4), 0.40)
        self.assertAlmostEqual(pm.utilization(4, 16), 16 / 22)      # 72.7 %
        self.assertAlmostEqual(pm.run_speedup(4, 4), 64 / 12)       # 5.3x
        self.assertAlmostEqual(pm.run_speedup(4, 16), 256 / 24)     # 10.7x


class WholeProduct(unittest.TestCase):
    """Spec 11.2: the three worked examples for N = 4, K_MAX = 16."""

    EXAMPLES = {
        # (M, K, P): (tiles, chunks, array busy, baseline busy, array host, baseline host)
        (4, 4, 4): (1, 1, 12, 64, 45, 97),
        (8, 8, 8): (4, 1, 64, 512, 260, 708),
        (4, 40, 4): (1, 3, 62, 640, 241, 819),
    }

    def test_spec_examples(self):
        for (m, k, p), want in self.EXAMPLES.items():
            c = pm.product_cycles(m, k, p)
            got = (c["tiles"], c["chunks"], c["array"]["busy"], c["baseline"]["busy"],
                   c["array"]["host"], c["baseline"]["host"])
            self.assertEqual(got, want, f"{m} x {k} x {p}")

    def test_hand_worked_chunks(self):
        # 4 x 40 x 4: runs of 16, 16 and 8. The first is normal (16 + 8 = 24),
        # the other two accumulate (16 + 7 = 23, 8 + 7 = 15): 24 + 23 + 15 = 62.
        self.assertEqual(pm.schedule_cycles(4, 40, 4)[0], 24 + 23 + 15)

    def test_closed_form_matches_schedule(self):
        # Two independent models of the same schedule must agree everywhere.
        for n in (2, 3, 4, 8):
            for k_max in (n, 16):
                for m in (1, n, n + 1, 3 * n):
                    for k in (1, k_max - 1 or 1, k_max, k_max + 1, 3 * k_max + 2):
                        for p in (1, n - 1 or 1, 2 * n + 1):
                            c = pm.product_cycles(m, k, p, n, k_max)
                            for design in ("array", "baseline"):
                                busy, host = pm.schedule_cycles(m, k, p, n, k_max, design)
                                self.assertEqual(
                                    (busy, host), (c[design]["busy"], c[design]["host"]),
                                    f"{design} N={n} K_MAX={k_max} {m}x{k}x{p}")

    def test_unknown_design_is_rejected(self):
        with self.assertRaises(ValueError):
            pm.schedule_cycles(4, 4, 4, design="gpu")


class Sweep(unittest.TestCase):
    def test_covers_n_2_to_8_and_k_1_to_32(self):
        rows = pm.sweep()
        self.assertEqual(len(rows), 7 * 32)
        self.assertEqual({r["n"] for r in rows}, set(range(2, 9)))
        self.assertEqual({r["k"] for r in rows}, set(range(1, 33)))

    def test_utilization_drops_when_a_second_chunk_starts(self):
        # N = 4: K = 16 is one chunk, 16 / 22; K = 17 is two, 17 / (17 + 12).
        rows = {(r["n"], r["k"]): r for r in pm.sweep()}
        self.assertAlmostEqual(rows[(4, 16)]["utilization"], 16 / 22)
        self.assertAlmostEqual(rows[(4, 17)]["utilization"], 17 / 29)

    def test_writes_csv(self):
        path = os.path.join(tempfile.mkdtemp(), "sub", "perf_sweep.csv")
        pm.write_sweep(path, pm.sweep())
        with open(path, encoding="ascii") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0].split(","), pm.SWEEP_FIELDS)
        self.assertEqual(len(lines), 1 + 7 * 32)


class Measurements(unittest.TestCase):
    def write_csv(self, text):
        path = os.path.join(tempfile.mkdtemp(), "measured.csv")
        with open(path, "w", encoding="ascii") as f:
            f.write(text)
        return path

    def test_phase1_measurements_match(self):
        path = os.path.join(REPO, "results", "phase1", "cycle_counts.csv")
        checked, mismatches = pm.check_file(path, "array", 4)
        self.assertEqual(checked, 106)
        self.assertEqual(mismatches, [])

    def test_baseline_format_of_64(self):
        path = self.write_csv("case,name,busy_cycles,cycle_count,expected_busy\n"
                              "0,identity,64,64,64\n")
        self.assertEqual(pm.check_file(path, "baseline", 4), (1, []))

    def test_k_len_and_accumulate_columns(self):
        path = self.write_csv("name,k_len,accumulate,busy_cycles\n"
                              "a,16,0,24\nb,16,1,23\nc,1,0,9\n")
        self.assertEqual(pm.check_file(path, "array", 4), (3, []))

    def test_whole_product_columns(self):
        path = self.write_csv("name,m,k,p,busy_cycles,host_cycles\n"
                              "chunks,4,40,4,62,241\n")
        self.assertEqual(pm.check_file(path, "array", 4), (1, []))

    def test_one_cycle_off_is_reported(self):
        path = self.write_csv("name,k_len,busy_cycles\nlate,4,13\n")
        checked, mismatches = pm.check_file(path, "array", 4)
        self.assertEqual(checked, 1)
        self.assertEqual(len(mismatches), 1)
        self.assertIn("measured 13, model 12", mismatches[0])

    def test_missing_files_are_skipped(self):
        out = io.StringIO()
        entries = [{"path": "does/not/exist.csv", "design": "array", "n": 4,
                    "source": "test"}]
        self.assertEqual(pm.check_measurements(entries, out=out), 0)
        self.assertIn("SKIP", out.getvalue())


if __name__ == "__main__":
    unittest.main()
