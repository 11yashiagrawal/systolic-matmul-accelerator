# Release-day clean-clone check - 16 November 2026

For [issue #21](https://github.com/vks-g/systolic-matmul-accelerator/issues/21).
This updates the [14 November preflight](clean_clone_2026-11-14.md) with checks
on the release-day repository. It records a specific snapshot, not a release tag.

**Verdict: automated functional checks pass; final release sign-off remains
pending.** The evaluator README is still awaiting integration in
[PR #54](https://github.com/vks-g/systolic-matmul-accelerator/pull/54), and interactive
viewer/browser checks could not be completed through Computer Use. Keep #21 open
until the remaining checks below are confirmed on the final `dev` revision.

## Snapshot and environment

- Fresh remote clone of `dev` at
  `97c621859e0b85e4502d2798b299e2fef4f42ab4`, checked on Monday, 16 November 2026.
- macOS 15.5, arm64; GNU Make 3.81; Icarus Verilog 13.0; Verilator 5.054;
  Python 3.11.15; NumPy 2.4.6; Tectonic 0.17.0; Surfer 0.7.0 (`11bb2e3`).
- New `.venv`, installed from `model/requirements.txt`, and newly generated
  vectors, simulation executables, logs and VCDs. No build output or Python
  environment was copied from another checkout.
- The host already had the simulators, Make and Tectonic named in
  [the setup guide](../../docs/setup.md). Its tool and TeX caches were not erased.
  The Surfer macOS ARM binary came from the official download linked by that
  guide and was placed on a temporary `PATH`. A temporary app wrapper was used
  for app identification; it is not a repository dependency.
- This verifies a clean checkout and Python environment, not provisioning on
  a newly installed OS. Docker's daemon was unavailable, so no container or
  alternate-OS run is claimed.

## Commands

After cloning `dev`, from its root, following `docs/setup.md`:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r model/requirements.txt
make lint
make test
python -m unittest discover -s model -v
python -m unittest discover -s tests -v
make waves
tectonic reports/phase1/main.tex
```

Python 3.11 was selected for the fresh environment; the supported requirement
is Python 3.10+. Surfer was on `PATH` and GTKWave was absent, so the unmodified
`make waves` command exercised the automatic Surfer fallback.

## Lint and simulation

All seven modules lint cleanly. All seven RTL testbenches pass, with no skips:

```text
PASS lint
PASS tb_input_skew_buffer 496/496
PASS tb_mac 20/20
PASS tb_output_buffer 96/96
PASS tb_pe 15/15
PASS tb_sa_controller 56/56
PASS tb_systolic_array 7471/7471
PASS tb_systolic_top 2195/2195
```

That is **10,349/10,349 RTL checks**. The top-level test regenerated and checked
106 golden products (six directed plus 100 random cases, seed 1).
The regenerated [cycle-count CSV](cycle_counts.csv) agrees with the committed
file: every case has 10 compute cycles, 12 busy cycles and `cycle_count = 12`.
The array bench also checks N = 3, with its own fixed seed, alongside N = 4.

The Python suites also pass:

| Suite | Result |
|---|---|
| Golden-model self-tests, `unittest discover -s model -v` | 17 tests, OK |
| Make/viewer-selection tests, `unittest discover -s tests -v` | 6 tests, OK |

## Waveform viewer

`make waves` reran the top-level simulation, selected Surfer automatically,
started the viewer process and successfully loaded the newly generated VCD.
The viewer logs include:

```text
Wave source is file
Watching file build/tb_systolic_top.vcd for changes
VCD file loaded
Loaded the body of build/tb_systolic_top.vcd
Loaded 140 variables
```

The viewer was stopped after startup/loading verification. This establishes
successful launch and parsing; interactive signal selection, zooming and visual
waveform inspection were not verified in this run. Computer Use access to the temporary Surfer app was not approved, so interactive
inspection remains unverified.

## Report build and rendering

`tectonic reports/phase1/main.tex` completed successfully from the clone root.
The log reports TeX, BibTeX, the reruns and PDF generation, with no undefined
reference, missing citation or missing input/figure error.

- Rebuilt report: **seven pages, 505,790 bytes**.
- Committed report: **seven pages, 505,788 bytes**.
- `pdftotext -layout` output is identical for both PDFs.
- All seven pages were rendered with Poppler at 85 DPI. A pixel comparison of
  each rebuilt/committed page is identical, and the rendered pages were visually
  inspected for page layout and figures.

The PDFs differ as binary files and have different creation times. The rebuilt
PDF and rendered comparison files remain under gitignored `build/release-check/`;
the tracked PDF was returned to the exact committed bytes after verification.
No report source, bibliography or published PDF is changed by this evidence PR.

## README and report links

The link audit covered **all nine tracked README files**, and external URLs and
DOIs in the report's `.tex` and `.bib` files. Local Markdown targets and heading
anchors were checked; report section inputs exist and the report build resolves
its bibliography and graphics.

| Check | Result |
|---|---|
| Local README references and anchors | 31 checked, all resolve |
| Distinct external README/report URLs | 29 checked |
| HTTP 200 | 19 URLs, including all four badges and the public video folder |
| HTTP 202 after DOI redirects | 8 IEEE URLs |
| HTTP 403 after DOI redirects | 2 ACM URLs; details below |
| HTTP 404 / network failures | None observed |

The ACM targets are:

- `10.1145/3079856.3080246`: *In-Datacenter Performance Analysis of a Tensor Processing Unit*.
- `10.1145/2749469.2750389`: *ShiDianNao*.

Both DOI URLs redirect to the expected ACM DOI pages, which return 403 from
this host. Crossref's public metadata API returns `status: ok`, the matching
DOI and the expected paper title for both. The identifiers are valid; access
to the publisher pages remains unverified from a normal reader's browser.
No bibliography URL was rewritten merely because automated access was restricted.

The [public video folder](https://drive.google.com/drive/folders/1d-p1YpFjd7gjbm1XGEC8u5PCso8LQxUw?usp=sharing)
returns HTTP 200 without credentials and lists `phase1_final.mp4`. An anonymous
download of that file succeeded (90,144,045 bytes). An isolated PyAV check reports
H.264 video, AAC audio and a duration of **282.7 seconds (4:42.7)**, below five
minutes. All 8,481 video frames and 13,252 audio frames decoded successfully through
282.67/282.69 seconds respectively. Frames at 5, 100, 200 and 275 seconds were
also visually inspected. This media check used a separate temporary Python
environment because the host ffprobe executable had a missing shared library;
no project dependency or system library was changed.
The same folder
is linked from the report and [video README](../../media/phase1/README.md).
The top-level README still lacks its final report/video presentation and current
status table at this snapshot; that work is already covered by #19 / PR #54.

## Remaining release checks

| Item | Required follow-up |
|---|---|
| Evaluator README | Review and merge PR #54, then recheck the final `dev` references and record its commit. |
| Interactive waveform check | On a permitted desktop, open the generated VCD with `make waves`, select signals and confirm rendering. Launch and file loading pass in this run. |
| Logged-out browser video playback | Confirm playback in a permitted logged-out browser. Anonymous download and full video/audio decoding pass, and the measured duration is below five minutes. Computer Use rejected Chrome access because the app was not approved. |
| ACM publisher pages | Open both DOI links in a normal logged-out browser; automated 403 responses do not establish broken identifiers. |
| Environment coverage | If release policy requires a newly provisioned machine, run the setup guide there; this host reused installed tools and caches. |

These limitations concern final sign-off, not a failing RTL regression. The
issue remains open, and this report does not merge a milestone or create a tag.
