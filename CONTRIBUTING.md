# Contributing to Emfy

Thanks for helping. Emfy is small and opinionated; the rules below keep it
shippable and legally clean. They are not suggestions.

## The most useful thing you can do

**Send files.** A real-world `.emf` that renders wrongly (or not at all) is
worth more than most code PRs:

1. Check you have the right to share the file publicly. Files from work, or
   exported from documents you don't own, usually don't qualify — see
   licensing below.
2. Open an issue with the file attached, what produced it (app + version if
   you know), and what looks wrong.
3. If you can, include the output of `emfy-dump`:

   ```sh
   cd EMFKit && swift build -c release
   .build/release/emfy-dump path/to/file.emf
   ```

Every confirmed misrender gets a corpus file and an issue reference before it
gets fixed — that's the regression policy.

## Corpus licensing rules (hard)

- `corpus/` (committed) accepts ONLY files that are self-generated or
  verifiably CC0/public-domain. Provenance goes in `corpus/README.md`.
- GPL-sourced test files (libemf2svg, libUEMF) and anything you can't
  redistribute stay out of the repo entirely. Maintainers keep such files in
  a local, gitignored `corpus-local/`.
- Never paste content, screenshots, or filenames of confidential files into
  issues, commits, or docs.

## Clean-room policy (hard)

The parser and renderer are implemented **from the public [MS-EMF]/[MS-WMF]
specifications only**. If you have read the EMF-handling source of
libemf2svg, libUEMF, LibreOffice, Inkscape, or Wine closely enough to
remember how they do it, please contribute corpus files and bug reports
rather than parser/renderer code. Cite the spec section
(e.g. “[MS-EMF] §2.3.5.8”) in comments for any non-obvious decode decision.

## Code expectations

- **Architecture is settled.** EMFParse imports Foundation only; EMFRender
  imports Foundation + CoreGraphics + CoreText only; no third-party
  dependencies anywhere (including test-only). PRs that violate this are
  declined regardless of quality.
- **The parse/render path treats every input as hostile.** No force-unwraps,
  no `try!`, no trapping conversions or unchecked/wrapping arithmetic on
  payload-derived values; validate every count and offset against the
  record's own size before allocating; decoders return typed failures.
  Log-and-skip is the failure mode — a partial render always beats an error.
- **Tests first.** A record decoder PR needs hand-built byte fixtures
  (including truncated and lying-size variants) before rendering work.
  Renderer changes must keep the committed snapshot baselines byte-identical
  or justify a re-record in the PR description.
- **Surgical diffs.** One concern per PR; no drive-by refactors.

## Building and testing

```sh
cd EMFKit
swift test                    # full suite: fixtures, snapshots, fuzz
xcodebuild -project ../Emfy/Emfy.xcodeproj -scheme Emfy build   # the app + QL extensions
```

Both must be green before review. For anything touching the parse path, run
the extended fuzz pass: `EMFY_FUZZ_ITERATIONS=2000 swift test`.

## Scope notes

- EMF+ (the GDI+ record set) is out of scope for v1: dual-format files render
  their GDI half; EMF+-only files render partially with an honest notice.
  EMF+ decoding PRs belong to a future v2 discussion issue first.
- Windows-specific niceties (OpenGL records, palettes, ROP modes beyond
  copy) are intentionally log-and-skip until a real corpus file demands them.
