# Emfy

![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Licence: MIT](https://img.shields.io/badge/licence-MIT-green)
![Release](https://img.shields.io/github/v/release/whosneet/emfy)

**Press space on an `.emf` file. See the picture.**

Emfy is a free, open-source viewer for EMF (Enhanced Metafile) files on
macOS. The viewer window is almost beside the point — the point is **Quick
Look**: spacebar previews in Finder and real thumbnails for `.emf` files,
which no free Mac tool currently provides.

## Why

EMF is the vector format Windows tools quietly export — diagrams out of
PowerPoint and Visio, charts out of Excel, drawings out of engineering and
risk tools. On a Mac today your options are paid converter apps, opening a
whole office suite or vector editor, or uploading the file to a website.
None of them give you the thing macOS should have anyway: press space, see
the picture.

## Status

**Version 1.0.0 — it works.** Press space on an `.emf` file in Finder and
the preview appears; thumbnails render right in the file listing. Direct
download: the notarized DMG on the
[releases page](https://github.com/whosneet/emfy/releases). App Store
listing: in progress.

What's inside:

- Safe parsing of any EMF file — bounds-checked end to end, fuzz-tested
  (16,000 hostile mutants, sanitizer-clean), zero crashes across a 249-file
  corpus that includes deliberately corrupted files.
- `emfy-dump` prints the record inventory, header dimensions, and
  diagnostics for any EMF file.
- Vector content — polygons, polylines, béziers, rectangles, ellipses, path
  brackets (fill, stroke, or both), clipping, pens including dashed styles,
  brushes, transforms — verified against LibreOffice renders of the same
  files.
- Text: Windows font names map to macOS fonts (with a substitution table),
  styled/rotated/accented runs, per-character advances, alignment,
  underline and strikeout.
- Embedded bitmaps: 24/32-bit and palettised DIBs, stretched, cropped, and
  mirrored — crisp, with correct colours.
- The viewer app: zoom, pan, fit, export to PNG or true-vector PDF, and an
  honest partial-rendering notice on files whose drawing content is
  EMF+-only (deferred to v2).
- Quick Look preview + Finder thumbnail extensions sharing the same
  renderer — notarized, sandboxed, no network access anywhere.

- [x] **Phase 1 — parse.** EMF header, record walker, `emfy-dump` inventory CLI
- [x] **Phase 2 — draw.** Pens, brushes, transforms, core geometry
- [x] **Phase 3 — paths.** Path brackets and clipping
- [x] **Phase 4 — text & images.** Font mapping, text runs, embedded bitmaps
- [x] **Phase 5 — the point.** Viewer app, Quick Look preview, Finder thumbnails
- [x] **Phase 6 — ship.** Hardening, notarised DMG, Mac App Store *(DMG released; App Store submission in progress)*

Each phase gates on real files rendering correctly before the next begins.

## Scope, honestly

- **EMF (GDI) is v1** — the few dozen record types that cover the
  overwhelming majority of real-world files.
- **EMF+ is v2.** Many modern exporters write dual-format files (GDI and
  GDI+ side by side); Emfy renders their GDI half, which is a complete
  picture. EMF+-only files render whatever GDI fallback they contain and
  say so in the UI — never a silent blank canvas.
- Malformed files half-render with a logged record list rather than erroring.

## Under the hood

```
EMFKit — Swift package, zero third-party dependencies
├── EMFParse    bytes → records         (Foundation only)
├── EMFRender   records → CGContext     (CoreGraphics + CoreText)
└── emfy-dump   record-inventory CLI — the debugging tool for odd files

Emfy.app + Quick Look preview & thumbnail extensions: thin shells over EMFKit
```

- **Clean-room.** Implemented from the public [MS-EMF]/[MS-WMF]
  specifications. No code from, or derived from, any existing EMF
  implementation.
- **Built for hostile input.** Quick Look parses files automatically the
  moment Finder shows them, so every size and count is bounds-checked before
  it is trusted, unknown records log-and-skip, decoders return typed
  failures, and the extensions run sandboxed with no network access anywhere.

## Install

Download `Emfy.dmg` from the
[latest release](https://github.com/whosneet/emfy/releases/latest), open it,
and drag Emfy to Applications. The app is notarized, so it opens without
Gatekeeper warnings. Finder thumbnails and spacebar previews activate after
the app has been launched once.

## Requirements & building

Runs on macOS 14.0 (Sonoma) or later; building needs Xcode 26 or newer
(Swift 6.2 toolchain).

The EMFKit package (parser + renderer + CLI):

```sh
cd EMFKit
swift test                                   # parser fixtures + renderer snapshots
swift build -c release
.build/release/emfy-dump path/to/file.emf    # record inventory + diagnostics
```

The app and Quick Look extensions:

```sh
xcodebuild -project Emfy/Emfy.xcodeproj -scheme Emfy -configuration Debug build
```

The build is ad-hoc signed for local development; a Developer ID signed,
notarised build (phase 6) is what enables the system to load the Quick Look
extensions.

## Contributing

Early days — issues and sample files are the most useful thing you can
offer, especially `.emf` files that render wrongly elsewhere. Only attach
files you have the rights to share publicly. A CONTRIBUTING guide arrives
with v1.

## Licence & references

MIT © 2026 Avneet Singh

- [MS-EMF] Enhanced Metafile Format — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emf/
- [MS-WMF] shared structures — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wmf/
- [MS-EMFPLUS] (v2 scope) — https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-emfplus/
