"""Measured speed-up of the systolic array over the sequential baseline (issue #69).

Joins the tiled-product rows of the two measured cycle-count files, product
by product, and writes results/phase2/speedup.csv:

* results/phase2/tiled_cycles.csv, written by tb_systolic_top (the array).
* The rows with set = tiled in results/phase2/baseline_cycles.csv, written by
  tb_seq_matmul (the baseline).

Both testbenches run the same products from sim/vectors/tiled/ through the same
host ports and the reference host schedule of docs/spec.md section 12, so the
busy cycles and the host cycles (loading, start pulses, busy cycles and
readout) compare like for like. Nothing here is predicted: every number comes
from the two files.

Run from the repository root, after make test:

    python model/speedup.py
"""

import argparse
import csv
import sys

ARRAY_CSV = "results/phase2/tiled_cycles.csv"
BASELINE_CSV = "results/phase2/baseline_cycles.csv"
OUT_CSV = "results/phase2/speedup.csv"

FIELDS = ["product", "name", "m", "k", "p", "macs",
          "array_busy", "baseline_busy", "busy_speedup",
          "array_host", "baseline_host", "host_speedup"]


def read_rows(path):
    with open(path, newline="", encoding="ascii") as f:
        return list(csv.DictReader(f))


def join(array_rows, baseline_rows):
    """One output row per product. Raises ValueError if the two files do not
    hold the same products in the same order."""
    baseline = [r for r in baseline_rows if r["set"] == "tiled"]
    if len(baseline) != len(array_rows):
        raise ValueError(f"{len(array_rows)} array products but {len(baseline)} baseline products")
    out = []
    for a, b in zip(array_rows, baseline):
        key_a = (a["product"], a["name"], a["m"], a["k"], a["p"])
        key_b = (b["case"], b["name"], b["m"], b["k"], b["p"])
        if key_a != key_b:
            raise ValueError(f"product mismatch: array {key_a}, baseline {key_b}")
        m, k, p = int(a["m"]), int(a["k"]), int(a["p"])
        ab, bb = int(a["busy_cycles"]), int(b["busy_cycles"])
        ah, bh = int(a["host_cycles"]), int(b["host_cycles"])
        out.append({
            "product": a["product"], "name": a["name"], "m": m, "k": k, "p": p,
            "macs": m * k * p,
            "array_busy": ab, "baseline_busy": bb, "busy_speedup": f"{bb / ab:.2f}",
            "array_host": ah, "baseline_host": bh, "host_speedup": f"{bh / ah:.2f}",
        })
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--array", default=ARRAY_CSV)
    ap.add_argument("--baseline", default=BASELINE_CSV)
    ap.add_argument("--out", default=OUT_CSV)
    args = ap.parse_args(argv)
    try:
        rows = join(read_rows(args.array), read_rows(args.baseline))
    except (OSError, KeyError, ValueError) as e:
        print(f"FAIL speedup: {e}", file=sys.stderr)
        return 1
    with open(args.out, "w", newline="", encoding="ascii") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    busy = [float(r["busy_speedup"]) for r in rows]
    host = [float(r["host_speedup"]) for r in rows]
    print(f"PASS speedup: {len(rows)} products in {args.out}; busy-cycle speed-up "
          f"{min(busy):.2f} to {max(busy):.2f}, end to end {min(host):.2f} to {max(host):.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
