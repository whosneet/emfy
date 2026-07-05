import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The EMF document model: a read-only `FileDocument` that parses its bytes
/// through EMFKit at open time and renders once to a `CGImage`.
///
/// Parsing and the first render happen in `init(configuration:)`; the document
/// then holds the immutable results. A file EMFKit cannot even give a header
/// for throws `CocoaError(.fileReadCorruptFile)` — the one failure surfaced to
/// the user. Everything past a valid header is best-effort (primer §8): a
/// partly-decodable file still opens, showing whatever rendered plus its
/// EMF+/skip diagnostics.
struct EMFDocument: FileDocument {
    /// Only EMF is readable. `.emf` has no system UTI; whichever installed
    /// app's imported declaration wins LaunchServices arbitration becomes the
    /// file's type, so we accept the known contenders. Ours
    /// (`com.microsoft.emf`, declared in `UTImportedTypeDeclarations`) always
    /// resolves; LibreOffice's exists only when LibreOffice is installed, so it
    /// is appended only when the system already knows it (`UTType(_:)` is
    /// failable and returns nil for an unregistered identifier).
    static var readableContentTypes: [UTType] {
        var types = [UTType(importedAs: "com.microsoft.emf")]
        if let libreOffice = UTType("org.libreoffice.emf-document") {
            types.append(libreOffice)
        }
        return types
    }

    /// The parsed file — retained for export (PDF re-render) and diagnostics.
    let file: EMFFile
    /// The rendered picture at retina scale, ready to display and to export as
    /// PNG. `nil` only if the bitmap context could not be allocated.
    let image: CGImage?
    /// Whether to show the EMF+ partial-rendering notice.
    let plusPresence: EMFPlusPresence
    /// The log-and-skip record from the first render (unimplemented records,
    /// approximations) — surfaced for diagnostics, never blocks display.
    let renderLog: [EMFRenderLog.Entry]

    /// The render scale used for the on-screen bitmap. 2 = retina; the 16384
    /// per-side cap in `EMFRenderer.makeImage` protects against absurd bounds.
    static let renderScale: CGFloat = 2

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // A missing/invalid header is the only unreadable case; map it to the
        // Cocoa "corrupt file" error so DocumentGroup shows the standard alert.
        let parsed: EMFFile
        do {
            parsed = try EMFFile.parse(data)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.file = parsed
        self.plusPresence = parsed.emfPlusPresence()

        if let (rendered, log) = EMFRenderer.makeImage(parsed, scale: Self.renderScale) {
            self.image = rendered
            self.renderLog = log.entries
        } else {
            self.image = nil
            self.renderLog = []
        }
    }

    /// Emfy never writes EMF files. Any save attempt is refused.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}
