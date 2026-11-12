## Related issue

Closes #<!-- Replace with the issue number, for example: Closes #6 -->

## What changed

<!-- Describe the module or document, and the behaviour it now has. -->

## How it was tested

<!-- Paste the commands you ran and the PASS/FAIL summary lines, e.g. `make lint` and `make sim-pe`. Attach a waveform capture if the change affects timing. -->

## Contribution checklist

- [ ] The base branch is `dev` (only milestone PRs from this repository's `dev` target `main`).
- [ ] This PR links its issue with `Closes #<number>`.
- [ ] `make lint` is clean and every testbench I touched prints `PASS`; any skipped check and its reason is recorded above.
- [ ] RTL follows the timing and interface contract in `docs/spec.md`; any change to it went through a spec PR first.
- [ ] Commits follow Conventional Commits and the changes follow `CONTRIBUTING.md`.
- [ ] One approving review is required before merging with **Create a merge commit**.
