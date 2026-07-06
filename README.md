<div align="center">

<img src="assets/emfy-icon.png" width="128" alt="Emfy app icon">

<h1>Emfy</h1>

<p><strong>Press space on an <code>.emf</code> file. See the picture.</strong></p>

<p>A free, open-source viewer for EMF (Enhanced Metafile) files on macOS —<br>
Quick Look previews, Finder thumbnails, and a small viewer app.</p>

<p>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform: macOS 14+"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-green" alt="Licence: MIT"></a>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/github/v/release/whosneet/emfy" alt="Latest release"></a>
<a href="https://github.com/whosneet/emfy/releases"><img src="https://img.shields.io/github/downloads/whosneet/emfy/total" alt="Downloads"></a>
</p>

<p>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/badge/Download-Emfy.dmg-0d96f6?style=for-the-badge&logo=apple&logoColor=white" alt="Download Emfy.dmg"></a>
</p>

</div>

---

EMF is the vector format Windows tools quietly export: diagrams out of
PowerPoint and Visio, charts out of Excel, drawings out of engineering
tools. macOS opens none of it. Emfy fixes that where you actually work —
the spacebar and the Finder window.

## Install

Download `Emfy.dmg` from the
[latest release](https://github.com/whosneet/emfy/releases/latest), open
it, and drag Emfy to Applications. Launch it once — Finder thumbnails and
spacebar previews activate from then on. The app is notarized, so it opens
without Gatekeeper warnings. Requires macOS 14.0 (Sonoma) or later.

## What it does

- **Quick Look, first-class.** Spacebar previews and Finder thumbnails for
  `.emf` files — the two things no free macOS tool offered.
- **Real-world record coverage.** Vector shapes, path brackets, clipping,
  dashed and styled pens, brushes, transforms, text (Windows font names
  mapped to macOS fonts — rotated and accented runs included), and
  embedded bitmaps.
- **A viewer, not just a peek.** Zoom, pan, fit-to-window; export to PNG
  or true-vector PDF.
- **Built for hostile input.** Quick Look parses files the moment Finder
  shows them, so every size and count is bounds-checked before it is
  trusted, unknown records are logged and skipped (a partial render always
  beats an error), the parser is fuzz-tested, and the app and extensions
  run sandboxed with no network access anywhere.
- **Clean-room implementation** from the public [MS-EMF]/[MS-WMF]
  specifications — no code from, or derived from, any existing EMF
  implementation.

**Scope, honestly:** modern exporters often write dual-format files (GDI
and EMF+ side by side) — these render fully from their GDI half. Files
whose drawing content exists *only* as EMF+ render partially and say so in
the viewer; EMF+ decoding is on the v2 list.

## Building from source

Xcode 26 or newer (Swift 6.2 toolchain).

The EMFKit package — parser, renderer, and the `emfy-dump` debugging CLI:

```sh
cd EMFKit
swift test                                   # fixtures, snapshots, fuzz
swift build -c release
.build/release/emfy-dump path/to/file.emf    # record inventory + diagnostics
```

The app and both Quick Look extensions:

```sh
xcodebuild -project Emfy/Emfy.xcodeproj -scheme Emfy -configuration Debug build
```

`corpus/` holds the self-generated test files the suite depends on.
`scripts/release.sh` is the notarized-release pipeline — point it at your
own signing identity if you ship a fork.

## Changelog

### 1.1

```
- Reliable PNG and PDF export, with a clear message if an export can't be completed instead of failing silently.
- A single Dock icon no matter how many files you open.
- EMF+ documents show the partial-rendering notice correctly again.
- More robust handling of large and malformed files — no hangs or runaway memory on hostile input.
- More memory-efficient Quick Look previews and Finder thumbnails.
- New Help menu: Developer Documentation, What's New, Changelog, and Contact the Developer.
```

### 1.0

```
- First public release.
- Quick Look spacebar previews and Finder thumbnails for .emf files.
- Vector shapes, paths, clipping, styled pens and brushes, transforms, text, and embedded bitmaps.
- Viewer with zoom, pan, fit-to-window, and export to PNG or true-vector PDF.
```

## Contributing

The most valuable contribution is a real `.emf` file that renders wrongly.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the file-licensing ground rules,
the clean-room policy, and code expectations.

## Licence & references

MIT © 2026 Avneet Singh

- [MS-EMF] Enhanced Metafile Format — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/
- [MS-WMF] shared structures — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/
- [MS-EMFPLUS] (v2 scope) — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/
