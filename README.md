<div align="center">

<img src="assets/emfy-icon.png" width="128" alt="Emfy app icon">

<h1>Emfy</h1>

<p><strong>Open an <code>.emf</code> or <code>.wmf</code> file. See the picture.</strong></p>

<p>A free, open-source viewer for EMF and WMF metafiles on Mac, iPhone and iPad —<br>
Quick Look previews, thumbnails, and a viewer app.</p>

<p>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20iOS%2017%2B-blue" alt="Platform: macOS 14+ | iOS 17+"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-green" alt="Licence: MIT"></a>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/badge/release-v3.1-blue" alt="Latest release: v3.1"></a>
</p>

<p>
<a href="https://github.com/whosneet/emfy/releases/latest"><img src="https://img.shields.io/badge/Download-Emfy.dmg-0d96f6?style=for-the-badge&logo=apple&logoColor=white" alt="Download Emfy.dmg"></a>
&nbsp;
<a href="https://apps.apple.com/app/emfy/id6787715125?mt=12"><img src="assets/badges/app-store-badge-black.svg" height="28" alt="Download Emfy on the Mac App Store"></a>
</p>

</div>

---

EMF and WMF are the vector formats Windows tools quietly export: diagrams
out of PowerPoint and Visio, charts out of Excel, drawings out of
engineering tools, and clip art from older Office documents. Apple's
platforms open none of it. Emfy fixes that where you actually work — the
spacebar and Finder on the Mac, the Files app and Mail on iPhone and iPad.

<img src="assets/screenshots/viewer-dark-flowchart.png" alt="Emfy rendering a complex dark-mode flowchart exported as an EMF file" width="100%">

## Install

Download `Emfy.dmg` from the
[latest release](https://github.com/whosneet/emfy/releases/latest), open
it, and drag Emfy to Applications. Launch it once — Finder thumbnails and
spacebar previews activate from then on. The app is notarized, so it opens
without Gatekeeper warnings. Requires macOS 14.0 (Sonoma) or later.

Prefer the store? The same app is on the
[Mac App Store](https://apps.apple.com/app/emfy/id6787715125?mt=12), where
updates install automatically.

On **iPhone and iPad**, Emfy is a universal app on the App Store (one
purchase covers Mac, iPhone and iPad). Open a file from Files or a Mail
attachment to view, zoom, share or export it, and Quick Look previews and
thumbnails show in Files, Mail and Messages. Requires iOS or iPadOS 17.0 or
later.

## What it does

- **Quick Look, first-class.** Spacebar previews and Finder thumbnails on
  the Mac, plus previews and thumbnails in Files, Mail and Messages on iPhone
  and iPad — for `.emf`, `.wmf`, `.emz` and `.wmz` files.
- **Real-world record coverage.** Vector shapes, path brackets, clipping,
  dashed and styled pens, brushes, transforms, text (Windows font names
  mapped to macOS fonts — rotated and accented runs included), embedded
  bitmaps, and EMF+ (GDI+) records — vector shapes, gradients, images, and
  text.
- **WMF too.** Windows Metafile (`.wmf`), placeable and plain, and the
  gzip-compressed `.emz` and `.wmz` forms. When a WMF carries a complete
  embedded EMF, Emfy plays that for higher fidelity.
- **A viewer, not just a peek.** Zoom, pan, fit-to-window; export to PNG
  or true-vector PDF. On iPhone and iPad, pinch-zoom stays sharp at any
  scale, with file details, sharing and Save to Photos.
- **Built for hostile input.** Quick Look parses files the moment Finder
  shows them, so every size and count is bounds-checked before it is
  trusted, unknown records are logged and skipped (a partial render always
  beats an error), the parser is fuzz-tested, and the app and extensions
  run sandboxed with no network access anywhere.
- **Clean-room implementation** from the public [MS-EMF]/[MS-WMF]
  specifications — no code from, or derived from, any existing EMF
  implementation.

**Scope, honestly:** EMF+ (GDI+) decoding shipped in 2.0. Dual-format files
(GDI and EMF+ side by side) now render from their higher-fidelity EMF+ half,
and files whose drawing content exists *only* as EMF+ render fully. A few
things are still simplified — hatch and path-gradient fills draw as solid
approximations, while texture fills, nested-metafile images, and exotic
image pixel formats are skipped — and Emfy itemizes every one in Render
Details instead of rendering silently. WMF support landed in 3.1; its gate
uses LibreOffice exports and hand-built fixtures, so Office-made WMFs that
render wrongly get fixed as they are reported.

## Screenshots

| | |
|:--:|:--:|
| <img src="assets/screenshots/quick-look.png" alt="Quick Look preview of an EMF file in Finder"> | <img src="assets/screenshots/finder-thumbnails.png" alt="Finder window showing real thumbnails for EMF files"> |
| *Spacebar preview, straight from Finder* | *Real thumbnails for `.emf` files* |
| <img src="assets/screenshots/viewer-text.png" alt="Emfy rendering EMF text with Windows fonts mapped to macOS"> | <img src="assets/screenshots/viewer-process-map.png" alt="Emfy rendering a process map with embedded bitmap content, zoomed to 125%"> |
| *Windows fonts mapped to macOS — weight, slant, and colour intact* | *Embedded bitmaps, zoomed and panned in the viewer* |

## Building from source

Xcode 26.6 or newer (Swift 6.2+ toolchain). The package, the app, and both
extensions build and pass their tests on Xcode 26.6 and on Xcode 27.2 / macOS 27.2.

The EMFKit package — parser, renderer, and the `emfy-dump` debugging CLI:

```sh
cd EMFKit
swift test                                   # fixtures, snapshots, fuzz
swift build -c release
.build/release/emfy-dump path/to/file.emf    # record inventory + diagnostics
```

If the checkout lives in an iCloud Drive (or other file-provider) folder,
Swift 6.4's build system cannot sign the test bundles: the sync service stamps
extended attributes onto `.build/` that `codesign` rejects. Keep the build
directory outside the synced folder instead:

```sh
swift test --no-parallel --scratch-path ~/Library/Caches/emfy-build
```

The app and both Quick Look extensions:

```sh
xcodebuild -project Emfy/Emfy.xcodeproj -scheme Emfy -configuration Debug build
```

`corpus/` holds the self-generated test files the suite depends on.
`scripts/release.sh` is the notarized-release pipeline — point it at your
own signing identity if you ship a fork.

## Changelog

### 3.1

```
- Windows Metafile (.wmf) files now open, preview, and thumbnail, alongside EMF.
- Compressed metafiles open too: .wmz (gzip-wrapped WMF) and .emz (gzip-wrapped EMF).
- WMF coverage spans the record types LibreOffice exports; when a WMF carries a complete embedded EMF, Emfy plays that for higher fidelity.
- New iPhone and iPad app: a viewer with sharp zoom at any scale, file details, and sharing or export to PNG and PDF.
- Quick Look previews and thumbnails for EMF and WMF files in Files, Mail, and Messages on iPhone and iPad.
- The iPhone and iPad app supports iPhone Duo.
- Steadier rendering of unusual and malformed metafiles.
```

### 2.0.2

```
- Refreshed app icon with the Liquid Glass effect.
- Leaner build: unused code is now stripped from the app and its Quick Look extensions.
```

### 2.0.1

```
- Verified on macOS 27.2: the viewer, Quick Look previews, and Finder thumbnails.
- Fixed a hang on macOS 27.2 where rendering text could stall indefinitely when several previews or thumbnails were drawn at once.
- Text now renders using only the fonts installed on your Mac, so opening or previewing a file can never trigger a font download.
```

### 2.0

```
- Full EMF+ (GDI+) rendering — vector shapes, gradients, images, and text now draw in the viewer, Quick Look previews, and Finder thumbnails.
- Dual-format files play their higher-fidelity EMF+ content instead of the GDI fallback.
- Files whose drawing content exists only as EMF+ now render fully, instead of showing a partial-rendering notice.
- Render Details itemizes any EMF+ feature Emfy approximated or skipped.
```

### 1.4

```
- Large embedded bitmaps are decoded only at the size they are shown, cutting memory use in Quick Look previews, Finder thumbnails, and the viewer window.
- Render Details notes when a bitmap was decoded below its full resolution — no visible detail is lost.
- Expanded automated rendering coverage for Chinese, Japanese, and Korean text.
```

### 1.3

```
- The viewer canvas now follows the system appearance, so the window and toolbar stay readable in Dark Mode.
```

### 1.2

```
- Oversized embedded bitmaps are safely skipped before they can consume excessive memory, keeping the viewer and Quick Look resilient to hostile files.
- New Render Details shows parsing diagnostics and rendering notes, including a clear no-diagnostics state.
- File ▸ Open… is always available with Command-O, while Emfy continues to avoid creating blank documents.
```

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

Product of Arrley, built by Neet Singh in Sydney, Australia

MIT © 2026 Arrley Pty Ltd

- [MS-EMF] Enhanced Metafile Format — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/
- [MS-WMF] shared structures — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/
- [MS-EMFPLUS] (v2 scope) — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/
