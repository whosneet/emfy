# Emfy

![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Licence: MIT](https://img.shields.io/badge/licence-MIT-green)
![Status: pre-alpha](https://img.shields.io/badge/status-pre--alpha-orange)

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

**Pre-alpha. Nothing renders yet.** The parser comes first, record by
record, built against the public [MS-EMF] specification.

- [ ] **Phase 1 — parse.** EMF header, record walker, `emfy-dump` inventory CLI
- [ ] **Phase 2 — draw.** Pens, brushes, transforms, core geometry
- [ ] **Phase 3 — paths.** Path brackets and clipping
- [ ] **Phase 4 — text & images.** Font mapping, text runs, embedded bitmaps
- [ ] **Phase 5 — the point.** Viewer app, Quick Look preview, Finder thumbnails
- [ ] **Phase 6 — ship.** Hardening, notarised DMG, Mac App Store

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

## Requirements

macOS 14.0 (Sonoma) or later. Building from source needs Xcode once the
package lands in phase 1 — watch the roadmap above.

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
