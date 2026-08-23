#!/usr/bin/env swift
//
// make-dmg-background.swift — deterministic generator for Emfy's DMG window
// background art.
//
//   swift scripts/make-dmg-background.swift <outdir>
//
// Writes background.png (700×450 px) and background@2x.png (1400×900 px) into
// <outdir>. The canvas is 700×450 POINTS with a TOP-LEFT origin (y increases
// downward): the drawing CTM is flipped once, and every text baseline is drawn
// through a per-line flip in the text matrix so glyphs come out upright (the
// classic flipped-context text trap). The art carries NO version number so the
// committed asset stays valid across every release.
//
// This is a standalone build/asset script — it is NOT part of EMFKit, so the
// EMFKit import rules (which bind EMFKit/Sources only) do not apply here; it may
// use AppKit / CoreGraphics / CoreText / ImageIO freely.

import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas constants (points, top-left origin)

let canvasW: CGFloat = 700
let canvasH: CGFloat = 450

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Palette (Emfy site palette — exact)

func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let r = CGFloat((v >> 16) & 0xFF) / 255
    let g = CGFloat((v >> 8) & 0xFF) / 255
    let b = CGFloat(v & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

let paper       = color("FCFCFA")
let paperShade  = color("F3F2EE")
let ink         = color("191C22")
let inkSoft     = color("4C4F56")
let rule        = color("C9C8C1")
let blue        = color("2050A0")
let green       = color("17743A")

// MARK: - Fonts

func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
}

let condensedCandidates = [
    "BarlowCondensed-Bold",
    "HelveticaNeue-CondensedBold",
    "AvenirNextCondensed-Bold",
]
var condensedName: String? = nil
for name in condensedCandidates where NSFont(name: name, size: 12) != nil {
    condensedName = name
    break
}
let condensedLabel = condensedName ?? "NSFont.systemFont(ofSize:weight:.bold) [fallback]"

func condensed(_ size: CGFloat) -> NSFont {
    if let name = condensedName, let f = NSFont(name: name, size: size) { return f }
    return NSFont.systemFont(ofSize: size, weight: .bold)
}

// MARK: - Text helpers (Core Text, positioned/oriented via the text matrix)

enum HAlign { case left, right }

func makeLine(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat) -> CTLine {
    // Use Core Text attribute keys explicitly: NSAttributedString's own
    // foreground-colour key ("NSColor") is not the key Core Text reads
    // ("CTForegroundColor"), so a plain .foregroundColor would silently draw
    // black once the string is handed to CTLine.
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    return CTLineCreateWithAttributedString(s as CFAttributedString)
}

func lineWidth(_ line: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// MARK: - Render

func render(scale: CGFloat) -> CGImage? {
    let pxW = Int(canvasW * scale)
    let pxH = Int(canvasH * scale)
    guard let ctx = CGContext(
        data: nil,
        width: pxW,
        height: pxH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    // points → device pixels, top-left origin, y down.
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: canvasH)
    ctx.scaleBy(x: 1, y: -1)

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSmoothing(false)   // grayscale AA only — deterministic, no LCD fringing
    ctx.setShouldSmoothFonts(false)

    // Draw an upright Core Text line whose baseline sits at (bx, by) in our
    // y-down space. The text matrix flips y back (d = -1) so glyphs render
    // upright, and its translation carries the baseline origin.
    func drawText(_ line: CTLine, baselineX bx: CGFloat, baselineY by: CGFloat) {
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: bx, ty: by)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func drawText(_ text: String, font: NSFont, color: NSColor, tracking: CGFloat,
                  x: CGFloat, baselineY by: CGFloat, align: HAlign = .left) {
        let line = makeLine(text, font: font, color: color, tracking: tracking)
        let bx = (align == .right) ? x - lineWidth(line) : x
        drawText(line, baselineX: bx, baselineY: by)
    }

    // 1. Fill the whole canvas with paper.
    ctx.setFillColor(paper.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

    // 2. Panel: x 48→652, y 116→334. Translucent shade fill + crisp 1pt rule.
    let panel = CGRect(x: 48, y: 116, width: 604, height: 218)
    ctx.setFillColor(paperShade.withAlphaComponent(0.45).cgColor)
    ctx.fill(panel)
    ctx.setStrokeColor(rule.cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(panel.insetBy(dx: 0.5, dy: 0.5))   // centred stroke lands on whole pixels

    // 3. Corner ticks: an L just inside each panel corner (subtle spec-sheet mark).
    let ti: CGFloat = 5.5   // inset from the panel edge (lands ticks on the .5 grid)
    let ta: CGFloat = 7     // arm length
    ctx.setStrokeColor(rule.cgColor)
    ctx.setLineWidth(1)
    ctx.setLineCap(.butt)
    func tick(cornerX cx: CGFloat, cornerY cy: CGFloat, dx: CGFloat, dy: CGFloat) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx + dx * ta, y: cy))   // horizontal arm
        ctx.addLine(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: cy + dy * ta)) // vertical arm
        ctx.strokePath()
    }
    let L = panel.minX, R = panel.maxX, T = panel.minY, B = panel.maxY
    tick(cornerX: L + ti, cornerY: T + ti, dx: 1,  dy: 1)   // top-left
    tick(cornerX: R - ti, cornerY: T + ti, dx: -1, dy: 1)   // top-right
    tick(cornerX: L + ti, cornerY: B - ti, dx: 1,  dy: -1)  // bottom-left
    tick(cornerX: R - ti, cornerY: B - ti, dx: -1, dy: -1)  // bottom-right

    // 4. Signal trace: blue→green gradient stroke, y=215, x 292→408, 1.6pt.
    ctx.saveGState()
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 292, y: 215))
    ctx.addLine(to: CGPoint(x: 408, y: 215))
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.butt)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if let grad = CGGradient(colorsSpace: srgb,
                             colors: [blue.cgColor, green.cgColor] as CFArray,
                             locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 292, y: 215),
                               end: CGPoint(x: 408, y: 215),
                               options: [])
    }
    ctx.restoreGState()

    // 5. Arrowhead: green triangle, apex (410,215), back edge 400,209.5→400,220.5.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 410, y: 215))
    ctx.addLine(to: CGPoint(x: 400, y: 209.5))
    ctx.addLine(to: CGPoint(x: 400, y: 220.5))
    ctx.closePath()
    ctx.setFillColor(green.cgColor)
    ctx.fillPath()

    // 6. Tag chip centred on the trace at (350,215): opaque, masks the trace.
    let chip = CGRect(x: 322, y: 205.5, width: 56, height: 19)
    let chipFill = CGPath(roundedRect: chip, cornerWidth: 2, cornerHeight: 2, transform: nil)
    ctx.addPath(chipFill)
    ctx.setFillColor(paper.cgColor)
    ctx.fillPath()
    let chipStroke = CGPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5),
                            cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
    ctx.addPath(chipStroke)
    ctx.setStrokeColor(rule.cgColor)
    ctx.setLineWidth(1)
    ctx.strokePath()
    do {
        let chipFont = mono(9.5, .semibold)
        let line = makeLine("DRAG", font: chipFont, color: inkSoft, tracking: 1)
        let w = lineWidth(line)
        let capHeight = CTFontGetCapHeight(chipFont as CTFont)
        drawText(line, baselineX: 350 - w / 2, baselineY: 215 + capHeight / 2)
    }

    // 7. Header line 1.
    drawText("EMF VIEWER FOR MACOS · INSTALL SHEET 1/1",
             font: mono(11, .regular), color: inkSoft, tracking: 0.8,
             x: 48, baselineY: 52)

    // 8. Header line 2.
    drawText("DRAG EMFY INTO /APPLICATIONS",
             font: condensed(18), color: ink, tracking: 0.5,
             x: 48, baselineY: 77)

    // 9. Pin row: six 7×12 pins, 5pt gaps, right edge at x=652, top at y=40.
    let pinW: CGFloat = 7, pinH: CGFloat = 12, pinGap: CGFloat = 5
    let pinCount = 6
    let rowW = CGFloat(pinCount) * pinW + CGFloat(pinCount - 1) * pinGap
    let rowLeft = 652 - rowW
    ctx.setFillColor(ink.cgColor)
    for i in 0..<pinCount {
        let x = rowLeft + CGFloat(i) * (pinW + pinGap)
        ctx.fill(CGRect(x: x, y: 40, width: pinW, height: pinH))
    }

    // 10. Spec label, right-aligned to x=652.
    drawText("macOS 14+ · MIT · NOTARISED",
             font: mono(10.5, .regular), color: inkSoft, tracking: 0,
             x: 652, baselineY: 77, align: .right)

    // 11. Wordmark.
    drawText("EMFY",
             font: condensed(28), color: ink, tracking: 1.5,
             x: 48, baselineY: 404)

    // 12. Tagline, right-aligned to x=652.
    drawText("press space · see the picture",
             font: mono(11, .regular), color: inkSoft, tracking: 0,
             x: 652, baselineY: 402, align: .right)

    return ctx.makeImage()
}

// MARK: - PNG I/O

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func pixelSize(of url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: swift make-dmg-background.swift <outdir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("error: cannot create \(outDir.path): \(error)\n".utf8))
    exit(1)
}

print("chosen condensed display font: \(condensedLabel)")

let jobs: [(name: String, scale: CGFloat)] = [
    ("background.png", 1),
    ("background@2x.png", 2),
]
for job in jobs {
    guard let image = render(scale: job.scale) else {
        FileHandle.standardError.write(Data("error: render failed for \(job.name)\n".utf8))
        exit(1)
    }
    let url = outDir.appendingPathComponent(job.name)
    guard writePNG(image, to: url) else {
        FileHandle.standardError.write(Data("error: PNG write failed for \(url.path)\n".utf8))
        exit(1)
    }
    print("wrote \(url.path)")
}

print("measured pixel dimensions:")
for job in jobs {
    let url = outDir.appendingPathComponent(job.name)
    if let (w, h) = pixelSize(of: url) {
        print("  \(job.name): \(w)×\(h) px")
    } else {
        print("  \(job.name): (could not measure)")
    }
}
