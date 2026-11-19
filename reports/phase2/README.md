# Final report (Phase 2)

`main.pdf` is the final report (IEEE conference format). The lead assembles and commits it in #63. The Phase 1 report in `../phase1/` stays as it was submitted.

- `main.tex` sets up the IEEEtran template and inputs one file per section from `sections/`, in the order the Phase 2 brief asks for: Abstract, Introduction, Literature Review, Proposed Solution, Verification, Results and Discussion, Individual Contributions, Conclusion and References.
- Each section file has one owner, assigned through its GitHub issue. The issue number is in the first line of each file. The sections were copied from Phase 1 to start from; each owner updates their own.
- Sections that are still missing are skipped, so the report builds at every step. Assembly (#63) makes them required.
- `refs.bib` holds every reference cited in the sections. Add an entry in the same PR as the section that cites it (#74).
- Figures are read from `figures/`, `../../results/phase2/figures/`, `../../results/phase2/waveforms/`, `../../results/phase1/waveforms/` and `../../docs/architecture/png/`. Build inside a full checkout of the repository.

## Sections and owners

| File | Heading | Owner | Issue |
|---|---|---|---|
| `abstract.tex` | Abstract and index terms | Gokul | #63 |
| `introduction.tex` | I. Introduction | Gokul | #63 |
| `literature_review.tex` | II. Literature Review | Yashi | #74 |
| `architecture_overview.tex` | III. Proposed Solution; A. Architecture Overview | Gokul | #63 |
| `pe_mac.tex` | B. Processing Element and MAC Unit | Milind | #67 |
| `dataflow.tex` | C. Dataflow and Input Skewing | Isha | #71 |
| `controller.tex` | D. Controller | Milind | #67 |
| `tiling.tex` | E. Tiling Products Larger than the Array | Gokul | #63 |
| `verification.tex` | IV. Verification Methodology | Affan | #78 |
| `results_discussion.tex` | V. Results and Discussion (heading and outline) | Gokul | #63 |
| `results.tex` | Latency, throughput and tiled performance | Isha | #71 |
| `baseline.tex` | Sequential baseline and the measured comparison | Milind | #67 |
| `synthesis.tex` | Synthesis results | Affan | #78 |
| `discussion.tex` | Discussion | Gokul | #63 |
| `contributions.tex` | VI. Individual Contributions | Gokul; each member checks their own row | #63 |
| `conclusion.tex` | VII. Conclusion | Gokul | #63 |

`results.tex`, `baseline.tex`, `synthesis.tex` and `discussion.tex` sit inside section V, so each starts with `\subsection{...}`, not `\section`. Every number in them must match a file in `results/phase2/`.

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

Check that your section builds with no overfull boxes, undefined references or BibTeX warnings before you open the PR. Only the lead commits `main.pdf`, at assembly.
