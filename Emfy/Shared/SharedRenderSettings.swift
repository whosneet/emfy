import EMFRender
import Foundation

/// A SwiftUI-free, non-isolated reader of the Rendering and Quick Look settings
/// from the App Group suite (S1b-2b). The Quick Look preview and thumbnail
/// extensions call `load(from:)` once per request to render exactly as the app
/// would, WITHOUT linking the app's `@Observable` `EmfySettings` model (which is
/// `@MainActor` and pulls in app-only code).
///
/// It is the single source of truth for the shared-suite key names and the two
/// Quick Look option types; `EmfySettings` references `SharedRenderSettings.Keys`
/// so the writer and this reader can never drift.
///
/// Every field falls back to its default when the value is missing, of the wrong
/// type, corrupt, or out of range — the extensions parse hostile input and must
/// never crash or allocate unboundedly (primer §8).
struct SharedRenderSettings: Sendable, Equatable {
    /// The thumbnail page background a Finder/Files icon is drawn on.
    enum ThumbnailBackground: String, CaseIterable, Sendable {
        /// Today's behaviour: dark ink stays legible on a white page.
        case white
        /// Transparent page, so the drawing sits on the tile with no white box.
        case transparent
    }

    /// How sharp a Quick Look preview is rendered — the long-edge pixel cap.
    enum PreviewSharpness: String, CaseIterable, Sendable {
        /// Today's caps, exactly (the long edge used before this option existed).
        case standard
        /// A larger long-edge cap, so a preview stays crisp on a large surface,
        /// still within each extension's recorded memory budget.
        case high
    }

    /// The EMFKit render options (antialiasing, font substitutions, EMF+-dual
    /// arbitration, WMF embedded-EMF), passed to every preview and thumbnail
    /// render call.
    var renderOptions: RenderOptions
    /// The thumbnail page background (thumbnails only — previews stay white).
    var thumbnailBackground: ThumbnailBackground
    /// The preview long-edge cap selector.
    var previewSharpness: PreviewSharpness

    /// The built-in defaults, reproducing every pre-option output exactly.
    init(
        renderOptions: RenderOptions = .default,
        thumbnailBackground: ThumbnailBackground = .white,
        previewSharpness: PreviewSharpness = .standard
    ) {
        self.renderOptions = renderOptions
        self.thumbnailBackground = thumbnailBackground
        self.previewSharpness = previewSharpness
    }

    /// Reads the shared suite once. A `nil` suite (unentitled, or the container
    /// couldn't resolve) yields the built-in defaults.
    static func load(from defaults: UserDefaults?) -> SharedRenderSettings {
        guard let d = defaults else { return SharedRenderSettings() }

        let antialiasing: RenderOptions.Antialiasing =
            d.string(forKey: Keys.renderEdges) == "crisp" ? .crisp : .smooth
        let arbitration: RenderOptions.EMFPlusArbitration =
            d.string(forKey: Keys.emfPlusSource) == "gdi" ? .gdi : .emfPlus
        // Absent key preserves today's default (true); a present key is honoured.
        let useEmbeddedEMF = d.object(forKey: Keys.useEmbeddedEMF) == nil
            ? true
            : d.bool(forKey: Keys.useEmbeddedEMF)
        let substitutions = Self.decodeSubstitutions(d.data(forKey: Keys.fontSubstitutions))

        let options = RenderOptions(
            antialiasing: antialiasing,
            fontSubstitutions: substitutions,
            emfPlusArbitration: arbitration,
            useEmbeddedEMF: useEmbeddedEMF
        )

        let background: ThumbnailBackground =
            d.string(forKey: Keys.thumbnailBackground) == "transparent" ? .transparent : .white
        let sharpness: PreviewSharpness =
            d.string(forKey: Keys.previewSharpness) == "high" ? .high : .standard

        return SharedRenderSettings(
            renderOptions: options,
            thumbnailBackground: background,
            previewSharpness: sharpness
        )
    }

    // MARK: - Font substitution decoding

    /// One persisted font-substitution row. A decode-only mirror of the app's
    /// `FontSubstitutionEntry` (which lives in the app model the extensions don't
    /// link); the `id` field in the JSON is ignored. Extra keys are tolerated.
    private struct Row: Decodable {
        let requested: String
        let replacement: String
    }

    /// The row cap this reader applies. Mirrors the renderer's own consumption
    /// cap (`FontMapper.userSubstitutionLimit`, internal to EMFRender) and the
    /// app's `EmfySettings.fontSubstitutionRowLimit`, so a hostile or stale blob
    /// can't make the extension map an unbounded table.
    static let substitutionRowLimit = 64

    /// The largest persisted font blob this reader will decode, before capping. A
    /// hostile or corrupt App Group value must never make a sandboxed extension
    /// allocate an unbounded JSON array (S-M4). 64 well-formed rows of two ≤128-char
    /// names fit comfortably; anything larger is rejected whole.
    static let maxBlobBytes = 64 * 1024
    /// The longest replacement/requested family name a row may carry. A LOGFONT face
    /// is at most 32 UTF-16 units and an EMF+ family is short too, so 128 is generous;
    /// a longer name is a sign of a bad blob and the row is dropped (S-M4).
    static let maxNameCharacters = 128

    /// Decodes the persisted table into render-time substitutions, matching the
    /// app's `renderOptions` mapping: reject an oversized blob before decoding, trim
    /// each name, drop any row with a blank or over-long requested or replacement
    /// family, and bound the count. Absent, oversized, or corrupt data yields an
    /// empty table.
    static func decodeSubstitutions(_ data: Data?) -> [FontSubstitution] {
        guard let data, data.count <= maxBlobBytes,
              let rows = try? JSONDecoder().decode([Row].self, from: data)
        else { return [] }
        return rows.prefix(substitutionRowLimit).compactMap { row in
            // Bound each name before any grapheme-cluster work: the cheap UTF-8 byte
            // count rejects an over-long name (≤ 4 bytes per character) without
            // walking it, so a hostile row can't make the extension hold a huge string
            // (S-M4).
            guard row.requested.utf8.count <= maxNameCharacters * 4,
                  row.replacement.utf8.count <= maxNameCharacters * 4
            else { return nil }
            let requested = row.requested.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = row.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty, !replacement.isEmpty,
                  requested.count <= maxNameCharacters, replacement.count <= maxNameCharacters
            else { return nil }
            return FontSubstitution(requestedFamily: requested, replacementFamily: replacement)
        }
    }

    // MARK: - Shared-suite keys (single source of truth)

    /// The keys the App Group suite holds. `EmfySettings` persists through exactly
    /// these, so they must never diverge — hence one definition, here, compiled
    /// into the app AND the extensions.
    enum Keys {
        static let renderEdges = "settings.rendering.edges"
        static let emfPlusSource = "settings.rendering.emfPlusSource"
        static let useEmbeddedEMF = "settings.rendering.useEmbeddedEMF"
        static let fontSubstitutions = "settings.rendering.fontSubstitutions"
        static let thumbnailBackground = "settings.quicklook.thumbnailBackground"
        static let previewSharpness = "settings.quicklook.previewSharpness"

        /// Every shared-suite key, for the one-time `.standard` → App Group
        /// migration in `EmfySettings`.
        static let all = [
            renderEdges, emfPlusSource, useEmbeddedEMF, fontSubstitutions,
            thumbnailBackground, previewSharpness,
        ]
    }
}
