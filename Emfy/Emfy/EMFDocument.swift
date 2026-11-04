import CoreGraphics
import EMFParse
import EMFRender
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The metafile document model: a read-only `FileDocument` that opens its bytes
/// through EMFKit's one front door at open time and renders once to a `CGImage`.
///
/// `OpenedMetafile.open` unwraps a gzip (.emz / .wmz) wrapper and sniffs the
/// format; `MetafileRenderer.prepare` parses the EMF or WMF exactly once. The
/// document then holds the immutable results. A file EMFKit cannot open (an
/// unrecognised format, a header-less EMF/WMF, or a broken gzip wrapper) throws
/// `CocoaError(.fileReadCorruptFile)` — the one failure surfaced to the user.
/// Everything past a valid header is best-effort (primer §8): a partly-decodable
/// file still opens, showing whatever rendered plus its diagnostics.
struct EMFDocument: FileDocument {
    /// Emfy reads EMF, WMF, placeable WMF, and their gzip-wrapped .emz / .wmz
    /// forms. None of these has a system UTI, so Emfy declares imported types
    /// (`com.microsoft.emf` / `.wmf` / `.emz` / `.wmz`) that always resolve;
    /// whichever installed app's declaration wins LaunchServices arbitration
    /// becomes the file's type, so the known contenders are also accepted.
    /// LibreOffice's identifiers exist only when LibreOffice is installed, so
    /// each is appended only when the system already knows it (`UTType(_:)` is
    /// failable and returns nil for an unregistered identifier).
    static var readableContentTypes: [UTType] {
        var types = [
            UTType(importedAs: "com.microsoft.emf"),
            UTType(importedAs: "com.microsoft.wmf"),
            UTType(importedAs: "com.microsoft.emz"),
            UTType(importedAs: "com.microsoft.wmz"),
        ]
        for identifier in ["org.libreoffice.emf-document", "org.libreoffice.wmf-document"] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        return types
    }

    /// The metafile parsed once through the front door — retained for export
    /// (PDF re-render), the natural size, and diagnostics.
    let prepared: MetafileRenderer.Prepared
    /// The rendered picture at retina scale, ready to display and to export as
    /// PNG. `nil` only if the bitmap context could not be allocated.
    let image: CGImage?
    /// The log-and-skip record from the first render (unimplemented records,
    /// approximations) — surfaced for diagnostics, never blocks display.
    let renderLog: [EMFRenderLog.Entry]
    /// Advisory front-door observations (gzip unwrap, signature sniff), surfaced
    /// in Render Details.
    let frontDoorDiagnostics: [MetafileDiagnostic]
    /// True when the input was a gzip-wrapped .emz / .wmz.
    let wasDecompressed: Bool

    /// The render scale used for the on-screen bitmap. 2 = retina; the 16384
    /// per-side cap in the renderer protects against absurd bounds.
    static let renderScale: CGFloat = 2

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    /// Opens, prepares, and renders raw metafile bytes — the same path the
    /// `FileDocument` initialiser takes, split out so the iOS app (which is not
    /// `DocumentGroup`-based) can build the model straight from `Data`. Mac
    /// behaviour is unchanged: `init(configuration:)` reads the file's bytes and
    /// delegates here.
    init(data: Data) throws {
        // A broken gzip wrapper, an unrecognised format, or a header-less
        // EMF/WMF are the only unreadable cases; map them to the Cocoa
        // "corrupt file" error so DocumentGroup shows the standard alert.
        let opened: OpenedMetafile
        do {
            opened = try OpenedMetafile.open(data)
        } catch {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let prepared = MetafileRenderer.prepare(opened) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.prepared = prepared
        self.frontDoorDiagnostics = opened.diagnostics
        self.wasDecompressed = opened.wasDecompressed

        if let (rendered, log) = MetafileRenderer.makeImage(prepared, scale: Self.renderScale) {
            self.image = rendered
            self.renderLog = log.entries
        } else {
            self.image = nil
            self.renderLog = []
        }
    }

    /// Emfy never writes metafiles. Any save attempt is refused.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}
