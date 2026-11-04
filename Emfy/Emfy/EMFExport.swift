import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// PNG encoding for an already-rendered image, plus the `fileExporter`
/// write-only document wrappers for PNG and PDF. PDF generation itself lives in
/// EMFKit's `MetafileRenderer.pdfData` so the same clean-room renderer produces
/// it for every metafile family; this type carries the encoded bytes to the
/// exporter. Kept free of AppKit.
enum EMFExport {
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
