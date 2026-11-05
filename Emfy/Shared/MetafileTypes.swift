import UniformTypeIdentifiers

/// The uniform types Emfy reads, shared by every open surface (the sidebar's
/// `fileImporter`, the Mac File ▸ Open panel). Moved out of the retired
/// `EMFDocument` (C3a slice 2) so the one declaration serves both platforms.
///
/// None of EMF / WMF / EMZ / WMZ has a system UTI, so Emfy declares imported types
/// (`com.microsoft.emf` / `.wmf` / `.emz` / `.wmz`) that always resolve; whichever
/// installed app's declaration wins LaunchServices arbitration becomes the file's
/// type, so the known contenders are also accepted. LibreOffice's identifiers
/// exist only when LibreOffice is installed, so each is appended only when the
/// system already knows it (`UTType(_:)` is failable).
enum MetafileTypes {
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
}
