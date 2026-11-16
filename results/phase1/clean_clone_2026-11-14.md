# Clean-clone preflight — 14 November 2026

**Verdict: not ready for final release sign-off.** This is an early preflight
for [issue #21](https://github.com/vks-g/systolic-matmul-accelerator/issues/21),
which requires a fresh final run on **Monday, 16 November**, before release.
Do not close #21 from this preflight PR.

## Snapshot and environment

- Cloned the remote `dev` branch separately into `/tmp/systolic-release-check-21`.
  Checked commit: `b414d35269aa7b8f33b99a0675329bc7f4e9b3cb`.
- macOS, ARM64; GNU Make 3.81, Icarus Verilog 13.0, Verilator 5.054,
  Python 3.15.0, NumPy 2.5.4, Tectonic 0.17.0, Surfer 0.7.0
  (`11bb2e3`). These are observed local versions, not pinned requirements.
- Created a new `.venv` and installed `model/requirements.txt` following
  [the setup guide](../../docs/setup.md). Simulation outputs and vectors
  were generated in that clone, not copied from the development checkout.
- The host's simulators and Tectonic were already installed. Its TeX/package
  caches were not erased. This is a clean **checkout and Python environment**,
  not proof of setup on a newly installed OS. A Docker CLI was present but
  its daemon was unavailable; no container run is claimed.

## Checks and the fix

| Check | Outcome |
|---|---|
| Fresh remote clone of `dev` | PASS at the exact commit above |
| Fresh Python environment and requirements install | PASS |
| `make lint test PYTHON=.venv/bin/python` | PASS: lint and all seven RTL testbenches |
| Original `make waves` with only Surfer on `PATH` | FAIL: `/bin/sh: gtkwave: command not found` |
| `make waves VIEWER=surfer` | Viewer launched and loaded the generated top-level VCD |
| Patched `make waves` with only Surfer on `PATH` | PASS: automatically selected Surfer; GUI and waveform rendering verified |
| Viewer-selection regression tests | PASS: 6 tests |
| Golden-model self-tests | PASS: 17 tests |
| `tectonic reports/phase1/main.tex` from the repository root | PASS: report built in `reports/phase1/main.pdf` |
| README/report local Markdown targets and heading anchors | PASS: 33 references |
| External link and final deliverable checks | INCOMPLETE: see below |

The setup guide recommends a Surfer binary on macOS, but Make previously
always defaulted to GTKWave. The fix prefers GTKWave when present, falls
back to Surfer, preserves explicit `VIEWER=...` commands, quoted executable paths and arguments,
and explains how to install a viewer if neither is available. CI now checks
these cases without opening a GUI.

The original `dev` clone was tested before applying the Makefile fix. The
patched Makefile and new regression tests were then applied to that clone
and rechecked with the same fresh virtual environment. The branch checkout
also passed the full RTL, model and viewer-selection suites.

For visual verification, the official Surfer macOS ARM binary was placed in
a temporary `.app` wrapper so desktop automation could identify it. This
wrapper is not a project dependency or a repository change. The actual
`make waves` command launched the viewer with `build/tb_systolic_top.vcd`;
the window showed that file, its 50,796,000 ps duration, and rendered signals
including `clk`, `start`, `busy`, `done`, `cycle_count` and `c_rdata`.

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

## Link audit and remaining release work

Checked all tracked `README.md` files and report `.tex`/`.bib` sources:
21 files, 33 local Markdown references and 23 distinct external URLs
(including bibliography DOI links). Local targets and heading anchors
resolved. Of the external URLs, 10 returned HTTP 200 and seven DOI targets
returned HTTP 202; this establishes HTTP reachability, not unrestricted
access to article text.

The following checks still need resolution or a final recheck:

| Item | Evidence / next step | Existing tracking |
|---|---|---|
| Published video | No video URL exists in the README or `media/phase1/README.md`; playback while logged out cannot be checked. | [#12](https://github.com/vks-g/systolic-matmul-accelerator/issues/12) |
| Submitted report PDF | The PDF builds, but `main.pdf` is not tracked at the checked `dev` commit. Assemble and commit the final report. | [#5](https://github.com/vks-g/systolic-matmul-accelerator/issues/5) |
| Report content | Dataflow, prototype status and verification sections contain placeholders at this snapshot. Verification is proposed in PR #43; the landscape system asset is proposed in PR #44 and needs the owner's `figure*` integration. | [#13](https://github.com/vks-g/systolic-matmul-accelerator/issues/13), [#20](https://github.com/vks-g/systolic-matmul-accelerator/issues/20), [#39](https://github.com/vks-g/systolic-matmul-accelerator/issues/39) |
| Evaluator README | Status rows still say planned; quick start and final report/video links are pending. | [#19](https://github.com/vks-g/systolic-matmul-accelerator/issues/19) |
| Badge endpoints | All four `img.shields.io` badges failed TLS connections from this host; retry from the release environment. No HTTP 404 was observed and no badge URL was rewritten. | [#21](https://github.com/vks-g/systolic-matmul-accelerator/issues/21) |
| Publisher access | The two ACM DOI links returned HTTP 403: `10.1145/3079856.3080246` and `10.1145/2749469.2750389`. Access restrictions do not establish that the DOI is invalid; recheck in a normal logged-out browser. | [#21](https://github.com/vks-g/systolic-matmul-accelerator/issues/21) |
| Final release-day check | Repeat on 16 November against the actual final `dev` commit, on a machine prepared from the setup guide. | [#21](https://github.com/vks-g/systolic-matmul-accelerator/issues/21) |

## Final run on 16 November

Use a new directory and clone the remote `dev` branch again. Record its full
commit SHA and all tool versions. Follow `docs/setup.md` for dependencies
and a fresh Python environment, then run from the clone root:

```sh
git rev-parse HEAD
make lint
make test
python -m unittest discover -s tests -v
python -m unittest discover -s model -v
make waves
tectonic reports/phase1/main.tex
```

Confirm the viewer displays the generated VCD, the report PDF builds and
contains the completed sections, the final PDF is tracked, and every
README/report link resolves. Play the published video while logged out.
Check the clone's `git status --short`: regenerated committed evidence
must be reviewed if it differs. Record PASS/FAIL results, the exact SHA,
environment and any remaining limitations as the final comment on #21;
close it only after every required release check passes.
