# Phase 1 report

`main.pdf` is the built report (IEEE conference format). The lead builds and commits it in #5.

- `main.tex` sets up the IEEEtran template and inputs one file per section from `sections/`, in report order.
- Each section file has one owner, assigned through its GitHub issue (the issue number is in the first line of each file). The report's Individual Contributions section lists who wrote and built what.
- `refs.bib` holds every reference cited in the sections. Add an entry in the same PR as the section that cites it; #16 consolidates them.
- Figures are read from `figures/`, `../../results/phase1/waveforms/` and `../../docs/architecture/png/`. Build inside a full checkout of the repository.

## Build

From this folder, with [Tectonic](https://tectonic-typesetting.github.io/) (it runs BibTeX itself):

```sh
tectonic main.tex
```

Or with a TeX Live install:

```sh
pdflatex main && bibtex main && pdflatex main && pdflatex main
```

Overleaf also works: upload this folder and set the compiler to pdfLaTeX. Copy your section back into the repo and commit it from your own account.

Rebuild `main.pdf` and commit it together with any change to a section or to `refs.bib`.
