# Testbenches

One self-checking testbench per RTL module, named `tb_<module>.v`. The rules are in [`CONTRIBUTING.md`](../CONTRIBUTING.md#8-verification-rules-non-negotiable):

- print a `PASS` or `FAIL` summary with counts;
- `$finish` on success, `$fatal(1, ...)` on any mismatch, so `make test` and CI fail;
- expected values come from the golden model in [`model/`](../model/) or from hand-worked values, never from the RTL's own output;
- dump waveforms into `build/` (ignored); commit only `.gtkw` layouts in `sim/waves/`.

Shared check macros go in `common/tb_utils.vh`.
