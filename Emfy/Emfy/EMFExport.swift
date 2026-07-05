import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Physical / pixel sizing derived from an EMF header, and the two export
/// encoders (PNG raster, PDF vector). Kept free of AppKit so the same math is
/// trivially auditable against the [MS-EMF] frame definition.
enum EMFExport {
    /// One point is 1/72 inch; one inch is 25.4 mm. `rclFrame` is in hundredths
    /// of a millimetre ([MS-EMF] §2.2.9), inclusive-inclusive.
    /// points = frameUnits / 100 (→ mm) / 25.4 (→ inch) × 72 (→ points).
    static let pointsPerFrameUnit = 72.0 / 25.4 / 100.0

    /// The document's physical page size in PostScript points, from the header
    /// frame. Falls back to the device-pixel bounds (at 1 pt/px) when the frame
    /// is degenerate, and to a 1×1 box as a last resort so the PDF media box is
    /// never empty.
    static func pageSizeInPoints(_ header: EMFHeader) -> CGSize {
        let frame = header.frame
        let widthUnits = Int64(frame.right) - Int64(frame.left) + 1
        let heightUnits = Int64(frame.bottom) - Int64(frame.top) + 1
        if widthUnits > 0, heightUnits > 0 {
            let w = Double(widthUnits) * pointsPerFrameUnit
            let h = Double(heightUnits) * pointsPerFrameUnit
            if w >= 1, h >= 1 { return CGSize(width: w, height: h) }
        }
        // Frame unusable: fall back to device bounds at 1 pt per pixel.
        let bounds = header.bounds
        let bw = Int64(bounds.right) - Int64(bounds.left) + 1
        let bh = Int64(bounds.bottom) - Int64(bounds.top) + 1
        if bw > 0, bh > 0 {
            return CGSize(width: Double(bw), height: Double(bh))
        }
        return CGSize(width: 1, height: 1)
    }

    /// Encodes a `CGImage` as PNG via ImageIO. Returns `nil` if no PNG
    /// destination can be created or finalised.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Renders `file` into a single-page, TRUE-VECTOR PDF sized to the header's
    /// physical frame in points, replaying the records through
    /// `EMFRenderer.render`. Returns `nil` only if the PDF context cannot be
    /// created.
    static func pdfData(from file: EMFFile) -> Data? {
        let pageSize = pageSizeInPoints(file.header)
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        context.beginPDFPage(nil)
        // White the page first — EMF has no page background of its own.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(mediaBox)
        _ = EMFRenderer.render(file, into: context, target: mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// A `FileDocument` wrapper carrying already-encoded PNG bytes, for
/// `.fileExporter`. Read is unsupported — this type only ever writes.
struct PNGExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A `FileDocument` wrapper carrying already-encoded PDF bytes, for
/// `.fileExporter`. Read is unsupported — this type only ever writes.
struct PDFExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
