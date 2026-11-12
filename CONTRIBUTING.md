# Contributing

## 1. One-time setup

```bash
git clone git@github.com:vks-g/systolic-matmul-accelerator.git
cd systolic-matmul-accelerator

# Use the email that is verified on YOUR GitHub account,
# otherwise your commits won't count in the contributors list.
git config user.name  "<your-github-username>"
git config user.email "<email-verified-on-your-github>"
```

Install the toolchain: Icarus Verilog, GTKWave (or Surfer), Verilator, and Python 3.10+ with NumPy for the golden model. Step-by-step instructions for macOS, Windows and Linux go in [`docs/setup.md`](docs/setup.md) (#17). Until that lands:

| OS | Command |
|---|---|
| macOS | `brew install icarus-verilog verilator` and `brew install --cask gtkwave` (or `brew install surfer`) |
| Ubuntu / WSL | `sudo apt install iverilog verilator gtkwave` |
| Windows | Icarus Verilog installer from bleyer.org/icarus (bundles GTKWave), or use WSL |

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r model/requirements.txt
```

## 2. Branches

| Branch | Purpose | Who merges into it |
|---|---|---|
| `main` | Stable milestones only. Tagged `v1.0-phase1`, `v2.0-phase2`. | Lead, from `dev` |
| `dev` | Integration branch. **All PRs target `dev`.** | Lead, after review |
| `<type>/<handle>/<topic>` | One short-lived branch per task | You |

Branch types: `feat`, `fix`, `docs`, `test`, `chore`.
Examples: `feat/MilindDevX/pe-mac`, `test/Bytebard089/top-e2e`, `docs/affan80/block-diagrams`.

## 3. Daily workflow

```bash
git switch dev && git pull
git switch -c feat/<handle>/<topic>

# ...work, commit small and often...
git add <files>
git commit -m "feat(pe): add signed multiply-accumulate unit"

git push -u origin feat/<handle>/<topic>
# Open a PR on GitHub: base = dev, link the issue ("Closes #6")
```

Keep your branch current with `git pull origin dev` before opening the PR. Delete the branch after it is merged.

## 4. Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>(<scope>): <what changed>`

| Type | Use for |
|---|---|
| `feat` | new RTL module, model script or feature |
| `fix` | bug fix |
| `test` | testbenches, test vectors, verification |
| `docs` | README, spec, diagrams, report sections |
| `refactor` | restructuring without behaviour change |
| `perf` | timing or area improvements (Phase 2) |
| `chore` | Makefile, CI, config, housekeeping |

Scopes are the module or area: `pe`, `array`, `buffers`, `control`, `top`, `model`, `tb`, `report`, `ci`.

Each commit should do one thing. "wip", "update", and "changes" are not commit messages.

## 5. Pull requests

- Base branch is `dev`. Never push directly to `dev` or `main`.
- Every PR needs **one approving review**. The lead reviews all PRs, and a second reviewer rotates among members.
- Merge with **"Create a merge commit"**. Do **not** squash: squashing collapses your commits into one and hides who did what.
- Every PR must link its issue. Issues are grouped under the `Phase 1` and `Phase 2` milestones.
- Paste the `PASS`/`FAIL` summary of the testbenches you ran into the PR description.

## 6. Ownership rules

- Every RTL module, testbench, model script and report section has one owner, assigned through its GitHub Issue.
- **Never edit a module you don't own.** If you need a change in someone else's module or in a shared interface, open a PR against [`docs/spec.md`](docs/spec.md) first and tag the owner.
- Each report section is its own file in `reports/phaseX/sections/`, written and committed by its owner.
- Add every paper you cite to `reports/phaseX/refs.bib` in the same PR as the section that cites it.

## 7. Verilog style

- `rtl/` holds **synthesizable Verilog-2005 only**: no `initial` blocks, no `#` delays, no `$display`.
- One module per file, and the file is named after the module (`rtl/pe/pe.v` holds `module pe`).
- Start every file, RTL and testbench, with `` `timescale 1ns / 1ps ``.
- Start every RTL file with `` `default_nettype none `` and end it with `` `default_nettype wire ``.
- Clock is `clk`. Reset is **synchronous, active-low** `rst_n`.
- Sequential logic: `always @(posedge clk)` with non-blocking `<=`. Combinational logic: `always @(*)` with blocking `=`, and a default for every output first, so no latches are inferred.
- Widths come from parameters (`N`, `DATA_W`, `ACC_W`), never from hard-coded numbers. Defaults live in `rtl/include/sa_params.vh`.
- Declare signed data as `signed` and sign-extend before accumulating.
- Signals are `lower_snake_case`; active-low signals end in `_n`.
- `make lint` (Verilator `--lint-only -Wall`) must be clean. If a warning is intentional, waive it on that line with a comment that says why.

## 8. Verification rules (non-negotiable)

- Every module in `rtl/` has a **self-checking** testbench `tb/tb_<module>.v`. It prints a `PASS` or `FAIL` summary with counts, calls `$finish` on success and `$fatal(1, ...)` on any mismatch, so CI fails when a test fails.
- Expected results come from the golden model in `model/` or from hand-worked values written in the testbench, **never** from copying what the RTL printed.
- Random tests use a fixed seed, and the seed is printed in the log.
- The timing contract in `docs/spec.md` is the reference: input skew (row `i` and column `j` delayed by `i` and `j` cycles), compute latency `K + 2N - 2` cycles, and the `start`/`busy`/`done` handshake. Changing it needs a spec PR first.
- Generated files (`build/`, vectors, `.vvp`, `.vcd`) are never committed; `make` regenerates them. Commit only `.gtkw` layouts (`sim/waves/`) and the logs and PNG captures used in the report (`results/phaseX/`).
