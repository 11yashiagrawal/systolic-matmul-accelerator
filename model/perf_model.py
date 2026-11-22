"""Performance model of the systolic array and the sequential baseline (issue #73).

Predicts every cycle count in docs/spec.md section 11, checks the
predictions against the cycle counts the testbenches measure, and draws the
figures for the report.

Two independent models, as in golden_model.py:

* Closed-form formulas from spec 11.1 and 11.2 (``array_busy_per_tile`` and
  the other ``*_per_tile`` functions).
* A schedule model that walks the runs of ``golden_model.plan_tiles`` one
  by one and adds up the cycles of each run under the reference host
  schedule of spec section 12 (``schedule_cycles``).

The two must agree for every product; the self-tests check that they do.

Run from the repository root:

    python model/perf_model.py              # check measurements, write figures
    python model/perf_model.py --check-only # only check measurements
"""

import argparse
import csv
import os
import sys

from golden_model import busy_cycles, ceil_div, compute_cycles, plan_tiles

N = 4               # SA_N
K_MAX = 16          # SA_K_MAX
N_RANGE = range(2, 9)     # N = 2 to 8 (issue #73)
K_RANGE = range(1, 33)    # K = 1 to 32 (issue #73)

FIGURE_DIR = os.path.join("results", "phase2", "figures")

# Measured cycle counts the testbenches write (spec section 10). Files that
# have not landed yet are skipped and reported as such.
MEASURED = [
    {"path": os.path.join("results", "phase1", "cycle_counts.csv"),
     "design": "array", "n": 4, "source": "tb_systolic_top, Phase 1 set (#11)"},
    {"path": os.path.join("results", "phase2", "baseline_cycles.csv"),
     "design": "baseline", "n": 4, "source": "tb_seq_matmul (#64)"},
    {"path": os.path.join("results", "phase2", "cycle_counts.csv"),
     "design": "array", "n": 4, "source": "tb_systolic_top, K != N set (#69)"},
    {"path": os.path.join("results", "phase2", "tiled_cycles.csv"),
     "design": "array", "n": 4, "source": "tb_tiled (#69)"},
]


# ---------------------------------------------------------------------------
# One run (spec 11.1)
# ---------------------------------------------------------------------------

def array_busy(n, k_len, accumulate=False):
    """Busy cycles of one array run: k_len + 2N, or k_len + 2N - 1 when it
    is an accumulate run, which skips CLEAR (spec 7.4 and 7.6)."""
    return busy_cycles(n, k_len, accumulate)


def baseline_busy(n, k_len):
    """Busy cycles of one baseline run: N^2 * k_len, normal or accumulate
    (spec 6.8). One MAC does every multiply-accumulate in turn."""
    return n * n * k_len


def macs(n, k_len):
    """Multiply-accumulates in one run: N^2 * k_len."""
    return n * n * k_len


def utilization(n, k_len):
    """Fraction of PE-cycles doing useful work during compute:
    N^2 k_len / (N^2 T) = k_len / (k_len + 2N - 2) (spec 11.1)."""
    return k_len / compute_cycles(n, k_len)


def run_speedup(n, k_len):
    """Busy-cycle speed-up of one run over the baseline (spec 11.1)."""
    return baseline_busy(n, k_len) / array_busy(n, k_len)


# ---------------------------------------------------------------------------
# A whole product, closed form (spec 11.2)
# ---------------------------------------------------------------------------

def tiles_and_chunks(m, k, p, n=N, k_max=K_MAX):
    """Output tiles ceil(M/N) * ceil(P/N) and chunks ceil(K/K_MAX)."""
    return ceil_div(m, n) * ceil_div(p, n), ceil_div(k, k_max)


def array_busy_per_tile(k, n=N, k_max=K_MAX):
    """K + chunks*(2N - 1) + 1: one normal run and chunks - 1 accumulate runs."""
    chunks = ceil_div(k, k_max)
    return k + chunks * (2 * n - 1) + 1


def array_host_per_tile(k, n=N, k_max=K_MAX):
    """(N + 1)K + 2N*chunks + 1 + N^2: loads, starts, busy cycles and the
    readout of the reference schedule."""
    chunks = ceil_div(k, k_max)
    return (n + 1) * k + 2 * n * chunks + 1 + n * n


def baseline_busy_per_tile(k, n=N):
    """N^2 * K."""
    return n * n * k


def baseline_host_per_tile(k, n=N, k_max=K_MAX):
    """N*K + chunks + N^2*K + N^2."""
    chunks = ceil_div(k, k_max)
    return n * k + chunks + n * n * k + n * n


def product_cycles(m, k, p, n=N, k_max=K_MAX):
    """Closed-form cycle counts of C = A x B (A is m x k, B is k x p).

    Returns a dict with ``tiles``, ``chunks``, ``runs``, ``macs`` (useful
    multiply-accumulates, without padding) and, for ``array`` and
    ``baseline``, the ``busy`` and ``host`` cycles.
    """
    tiles, chunks = tiles_and_chunks(m, k, p, n, k_max)
    return {
        "tiles": tiles,
        "chunks": chunks,
        "runs": tiles * chunks,
        "macs": m * k * p,
        "array": {"busy": tiles * array_busy_per_tile(k, n, k_max),
                  "host": tiles * array_host_per_tile(k, n, k_max)},
        "baseline": {"busy": tiles * baseline_busy_per_tile(k, n),
                     "host": tiles * baseline_host_per_tile(k, n, k_max)},
    }


# ---------------------------------------------------------------------------
# A whole product, run by run (spec section 12, reference host schedule)
# ---------------------------------------------------------------------------

def schedule_cycles(m, k, p, n=N, k_max=K_MAX, design="array"):
    """Walk the runs of ``plan_tiles`` and add up their cycles.

    Under the reference schedule each run loads its A and B blocks in
    parallel (N * k_len cycles), pulses start (1 cycle) and waits through
    its busy cycles; the next run's loads begin in the first DONE cycle.
    After a tile's last chunk the host reads its N^2 elements of C.

    Returns ``(busy, host)``. This is a second model of spec 11.2: it never
    uses the closed-form formulas.
    """
    busy = host = 0
    runs = plan_tiles(m, k, p, n, k_max)
    for i, run in enumerate(runs):
        k_len = run["k_len"]
        if design == "array":
            run_busy = array_busy(n, k_len, run["accumulate"])
        elif design == "baseline":
            run_busy = baseline_busy(n, k_len)
        else:
            raise ValueError(f"unknown design {design!r}")
        busy += run_busy
        host += n * k_len + 1 + run_busy
        last_chunk = i + 1 == len(runs) or runs[i + 1]["chunk"] == 0
        if last_chunk:
            host += n * n
    return busy, host


# ---------------------------------------------------------------------------
# Sweep over N and K (issue #73)
# ---------------------------------------------------------------------------

SWEEP_FIELDS = ["n", "k", "k_max", "chunks", "array_busy", "array_host",
                "baseline_busy", "baseline_host", "busy_speedup", "host_speedup",
                "utilization", "macs_per_cycle"]


def sweep(n_range=N_RANGE, k_range=K_RANGE, k_max=K_MAX):
    """One N x N output tile with inner dimension K, for every N and K.

    K above K_MAX runs as chunks, so utilization counts every chunk's fill
    and drain: K / (K + chunks*(2N - 2)). MACs per cycle are N^2 K over the
    array's busy cycles.
    """
    rows = []
    for n in n_range:
        km = max(k_max, n)  # spec section 3: K_MAX >= N
        for k in k_range:
            c = product_cycles(n, k, n, n, km)
            chunks = c["chunks"]
            rows.append({
                "n": n, "k": k, "k_max": km, "chunks": chunks,
                "array_busy": c["array"]["busy"], "array_host": c["array"]["host"],
                "baseline_busy": c["baseline"]["busy"],
                "baseline_host": c["baseline"]["host"],
                "busy_speedup": c["baseline"]["busy"] / c["array"]["busy"],
                "host_speedup": c["baseline"]["host"] / c["array"]["host"],
                "utilization": k / (k + chunks * (2 * n - 2)),
                "macs_per_cycle": n * n * k / c["array"]["busy"],
            })
    return rows


def write_sweep(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="ascii") as f:
        w = csv.DictWriter(f, fieldnames=SWEEP_FIELDS, lineterminator="\n")
        w.writeheader()
        for row in rows:
            w.writerow({key: (f"{v:.4f}" if isinstance(v, float) else v)
                        for key, v in row.items()})


# ---------------------------------------------------------------------------
# Checking measured cycle counts
# ---------------------------------------------------------------------------

def predict_row(row, design, n, k_max=K_MAX):
    """Predicted values for one measured CSV row, keyed like the row.

    Understood columns:

    * ``busy_cycles``, ``cycle_count``: busy cycles of one run, from
      ``k_len`` (default N), ``accumulate`` (default 0) and ``n`` (default
      the file's N).
    * ``compute_cycles``: k_len + 2N - 2 (array only).
    * For a whole product, ``m``, ``k`` and ``p`` with ``busy_cycles`` and,
      if present, ``host_cycles``.

    A ``design`` column overrides the file's design for that row.
    """
    design = row.get("design", design) or design
    n = int(row.get("n") or n)
    predicted = {}
    if all(row.get(col) not in (None, "") for col in ("m", "k", "p")):
        c = product_cycles(int(row["m"]), int(row["k"]), int(row["p"]), n, k_max)
        predicted["busy_cycles"] = c[design]["busy"]
        predicted["host_cycles"] = c[design]["host"]
        return predicted
    k_len = int(row.get("k_len") or n)
    accumulate = str(row.get("accumulate") or "0").strip() not in ("0", "false", "False")
    busy = array_busy(n, k_len, accumulate) if design == "array" else baseline_busy(n, k_len)
    predicted["busy_cycles"] = busy
    predicted["cycle_count"] = busy
    if design == "array":
        predicted["compute_cycles"] = compute_cycles(n, k_len)
    return predicted


def check_file(path, design, n, k_max=K_MAX):
    """Compare every row of a measured CSV with the model.

    Returns ``(rows_checked, mismatches)``; each mismatch is a string naming
    the row, the column, the measured value and the predicted one.
    """
    checked, mismatches = 0, []
    with open(path, newline="", encoding="ascii") as f:
        for line, row in enumerate(csv.DictReader(f), start=2):
            predicted = predict_row(row, design, n, k_max)
            compared = False
            for column, want in predicted.items():
                if row.get(column) in (None, ""):
                    continue
                compared = True
                if int(row[column]) != want:
                    name = row.get("name", "")
                    mismatches.append(f"{path}:{line} {name} {column}: "
                                      f"measured {row[column]}, model {want}")
            checked += compared
    return checked, mismatches


def check_measurements(entries=MEASURED, k_max=K_MAX, out=sys.stdout):
    """Check every measured file that exists. Returns the number of
    mismatches; files that have not landed are listed as skipped."""
    total_mismatches = 0
    for entry in entries:
        if not os.path.exists(entry["path"]):
            print(f"SKIP {entry['path']}: not measured yet ({entry['source']})", file=out)
            continue
        checked, mismatches = check_file(entry["path"], entry["design"], entry["n"], k_max)
        for m in mismatches:
            print(f"MISMATCH {m}", file=out)
        status = "PASS" if not mismatches else "FAIL"
        print(f"{status} {entry['path']}: {checked - len(mismatches)}/{checked} rows "
              f"match the model ({entry['source']})", file=out)
        total_mismatches += len(mismatches)
    return total_mismatches


def measured_points(entries=MEASURED):
    """(design, n, k_len, busy) of every single-run row that was measured,
    for marking on the figures."""
    points = set()
    for entry in entries:
        if not os.path.exists(entry["path"]):
            continue
        with open(entry["path"], newline="", encoding="ascii") as f:
            for row in csv.DictReader(f):
                if row.get("m") or not row.get("busy_cycles"):
                    continue
                design = row.get("design") or entry["design"]
                n = int(row.get("n") or entry["n"])
                k_len = int(row.get("k_len") or n)
                points.add((design, n, k_len, int(row["busy_cycles"])))
    return sorted(points)


# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------

# Categorical slots 1 to 3 of the project's chart palette, in fixed order,
# with a distinct marker per series so the figures still read in grayscale.
SERIES = [("#2a78d6", "o"), ("#eb6834", "s"), ("#1baf7a", "^")]
INK, INK_2, GRID = "#0b0b0b", "#52514e", "#e4e3df"


def _style(ax, xlabel, ylabel):
    ax.set_xlabel(xlabel, color=INK_2)
    ax.set_ylabel(ylabel, color=INK_2)
    ax.grid(True, color=GRID, linewidth=0.6)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(INK_2)
    ax.tick_params(colors=INK_2)


def plot_cycles_vs_size(ax, n=N, k_max=K_MAX, sizes=range(4, 65, 4)):
    """Busy and host cycles of square products S x S x S, array and baseline."""
    sizes = list(sizes)
    for (design, label), (color, marker) in zip(
            (("array", "Systolic array"), ("baseline", "Sequential baseline")), SERIES):
        busy = [product_cycles(s, s, s, n, k_max)[design]["busy"] for s in sizes]
        host = [product_cycles(s, s, s, n, k_max)[design]["host"] for s in sizes]
        ax.plot(sizes, busy, color=color, marker=marker, markersize=5, linewidth=2,
                markevery=2, label=f"{label}, busy")
        ax.plot(sizes, host, color=color, marker=marker, markersize=5, linewidth=2,
                markevery=2, linestyle="--", markerfacecolor="white",
                label=f"{label}, with load and readout")
    ax.set_yscale("log")
    ax.set_xticks(sizes[1::2])
    _style(ax, "Matrix size S (an S×S by S×S product)", "Cycles (log scale)")
    ax.set_title(f"Cycles per product, N = {n}, K_MAX = {k_max}", color=INK, fontsize=10)


def plot_speedup_vs_n(ax, k_values=(4, 8, 16), k_max=K_MAX):
    """Busy-cycle speed-up over the baseline for one N x N tile.

    K above K_MAX is left out: it runs as chunks of K_MAX, so its speed-up
    stays close to the K = K_MAX line (the sweep CSV has every K)."""
    ns = list(N_RANGE)
    for k, (color, marker) in zip(k_values, SERIES):
        speedup = [product_cycles(n, k, n, n, max(k_max, n))["baseline"]["busy"]
                   / product_cycles(n, k, n, n, max(k_max, n))["array"]["busy"] for n in ns]
        ax.plot(ns, speedup, color=color, marker=marker, markersize=6, linewidth=2,
                label=f"K = {k}")
        ax.annotate(f"K = {k}", (ns[-1], speedup[-1]), xytext=(6, 0),
                    textcoords="offset points", va="center", fontsize=8, color=INK)
    ax.plot(ns, [n * n for n in ns], color=INK_2, linewidth=1, linestyle=":",
            label="Peak, N²")
    ax.set_xticks(ns)
    ax.set_xlim(ns[0] - 0.3, ns[-1] + 1.2)
    _style(ax, "Array size N", "Speed-up over the baseline (busy cycles)")
    ax.set_title("Speed-up for one N×N tile", color=INK, fontsize=10)
    ax.legend(frameon=False, fontsize=8, labelcolor=INK, loc="upper left")


def plot_utilization_vs_k(ax, n_values=(2, 4, 8), k_max=K_MAX):
    """Compute utilization against K, counting each chunk's fill and drain."""
    ks = list(K_RANGE)
    for n, (color, marker) in zip(n_values, SERIES):
        km = max(k_max, n)
        util = [100 * k / (k + ceil_div(k, km) * (2 * n - 2)) for k in ks]
        ax.plot(ks, util, color=color, marker=marker, markersize=4, linewidth=2,
                label=f"N = {n}")
    ax.axvline(k_max + 0.5, color=INK_2, linewidth=1, linestyle=":")
    ax.annotate(f"K > {k_max}: two chunks", (k_max + 0.5, 99), xytext=(4, 0),
                textcoords="offset points", fontsize=8, color=INK_2, va="top")
    ax.set_ylim(0, 100)
    ax.set_xlim(0, ks[-1] + 1)
    _style(ax, "Inner dimension K", "PE utilization during compute (%)")
    ax.set_title(f"Utilization, K_MAX = {k_max}", color=INK, fontsize=10)
    ax.legend(frameon=False, fontsize=8, labelcolor=INK, loc="lower right")


def write_figures(out_dir=FIGURE_DIR, points=None):
    """Write the three report figures as PDF (for LaTeX) and PNG (for the
    README and slides). Measured single runs are marked on the cycles figure."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    plt.rcParams.update({"font.size": 9, "pdf.fonttype": 42,
                         "savefig.bbox": "tight", "savefig.dpi": 200})
    os.makedirs(out_dir, exist_ok=True)
    written = []
    figures = (
        ("cycles_vs_size", plot_cycles_vs_size),
        ("speedup_vs_n", plot_speedup_vs_n),
        ("utilization_vs_k", plot_utilization_vs_k),
    )
    for name, draw in figures:
        tall = name == "cycles_vs_size"  # its legend goes below the axes
        fig, ax = plt.subplots(figsize=(3.5, 3.3 if tall else 2.6))  # one IEEE column
        draw(ax)
        if tall:
            if points:
                for design, n, k_len, busy in points:
                    if n == N and k_len == N:
                        ax.plot([N], [busy], linestyle="none", marker="x", color=INK,
                                markersize=7, zorder=5)
                ax.plot([], [], linestyle="none", marker="x", color=INK,
                        label="Measured single run")
            ax.legend(frameon=False, fontsize=7, labelcolor=INK, loc="upper center",
                      bbox_to_anchor=(0.5, -0.22))
        for ext in ("pdf", "png"):
            path = os.path.join(out_dir, f"{name}.{ext}")
            fig.savefig(path, metadata={"CreationDate": None} if ext == "pdf" else None)
            written.append(path)
        plt.close(fig)
    return written


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--check-only", action="store_true",
                   help="only compare the measured cycle counts with the model")
    p.add_argument("--out", default=FIGURE_DIR, help="directory for figures and the sweep")
    args = p.parse_args(argv)

    mismatches = check_measurements()
    if not args.check_only:
        write_sweep(os.path.join(args.out, "perf_sweep.csv"), sweep())
        for path in write_figures(args.out, measured_points()):
            print(f"Wrote {path}")
        print(f"Wrote {os.path.join(args.out, 'perf_sweep.csv')}")
    if mismatches:
        print(f"FAIL perf_model: {mismatches} measured values differ from the model")
        return 1
    print("PASS perf_model: every measured value matches the model")
    return 0


if __name__ == "__main__":
    sys.exit(main())
