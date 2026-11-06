import CoreGraphics
import CoreText
import EMFParse
import Foundation

/// LOGFONT → CTFont resolution (primer §6 phase 4). Produces a `ResolvedFont`
/// carrying a base CTFont at a nominal size plus the attributes CoreText's font
/// object does not itself carry; the text drawer scales the base to the device
/// point size and applies underline/strike-out/rotation at draw time.
///
/// Resolution order:
///  1. Try the face name (auto-activation off). CoreText silently substitutes a
///     fallback when a family is missing, so a MISS is detected by comparing
///     the created font's family name against the request (case- and
///     space-insensitive). On a miss, consult the substitution table.
///  2. Apply bold (lfWeight ≥ 600) and italic (lfItalic ≠ 0) as symbolic
///     traits; if the trait variant does not exist, keep the base (no log).
///
/// Every family that had to be substituted is reported ONCE to the caller via
/// `fontSubstituted(requested:used:)` (coalesced per requested family).
enum FontMapper {

    /// The nominal size the base CTFont is created at. The text drawer copies
    /// the base to the true device size, so this value only sets a starting
    /// point for trait resolution — it never reaches the canvas directly.
    static let nominalSize: CGFloat = 100

    /// The default point size when lfHeight is 0 ([MS-EMF] §2.2.13 / primer:
    /// "font mapper default"), in logical units before the transform scale.
    static let defaultHeight: CGFloat = 12

    /// The ceiling on a resolved device point size. A glyph cannot usefully
    /// exceed the canvas (capped at `EMFRenderer.canvasDimensionCap`, 16384 per
    /// side), so anything larger only feeds CoreText/CTLine an enormous size to
    /// flatten glyph outlines at before CG clips — a slow, large-allocation path
    /// from a single hostile EMR_EXTCREATEFONTINDIRECTW with, say,
    /// `lfHeight = -2_000_000_000` (§8: never hang). Half the canvas cap is
    /// still far larger than any glyph a real file draws (normal sizes are a few
    /// hundred points at most), so legitimate text is untouched.
    static let maxDevicePointSize: CGFloat = 8192

    /// The default substitution when a requested family neither resolves
    /// directly nor has a table entry.
    static let defaultFamily = "Helvetica Neue"

    /// The cap on how many user font substitutions are consulted, and on each
    /// family name's length (S1b RenderOptions). The table comes from app
    /// settings, not from the hostile file, but it is bounded defensively so a
    /// pathological settings value cannot slow resolution.
    static let userSubstitutionLimit = 64
    static let familyNameLengthLimit = 128
    /// The cap on a file-supplied requested family name. A LOGFONT face is at most
    /// 32 UTF-16 units ([MS-EMF] §2.2.13) and EMF+ family names are short too, so 256
    /// is generous; a longer name is hostile input and is truncated before any
    /// normalise/lookup touches it (S-L5, primer §8).
    static let requestedFamilyLengthLimit = 256

    /// A system font created ONCE and cached — the emergency fallback a queued
    /// lookup returns if it times out. The lookup machinery is what stalled, so
    /// the fallback must already exist and perform no new lookup; it is built on
    /// the lookup queue (never a cooperative thread) to keep even this bootstrap
    /// clear of the macOS 27.2 deadlock. Accessed eagerly as every `run` call's
    /// `fallback`, so it is created on the first healthy lookup and cached for any
    /// later timeout. `nonisolated(unsafe)`: CTFont carries no Sendable
    /// annotation in the SDK, but it is immutable and thread-safe once created.
    nonisolated(unsafe) static let emergencyFallbackFont: CTFont = FontLookupQueue.preCreateFont {
        CTFontCreateUIFontForLanguage(.system, nominalSize, nil)
            ?? CTFontCreateWithNameAndOptions(defaultFamily as CFString, nominalSize, nil, .preventAutoActivation)
    }

    /// The system font, used for stock FONT selections. Created once per call;
    /// CoreText caches descriptors internally, so this is cheap.
    static func systemBaseFont() -> CTFont {
        FontLookupQueue.run(fallback: emergencyFallbackFont) {
            CTFontCreateUIFontForLanguage(.system, nominalSize, nil)
                ?? font(named: defaultFamily)
        }
    }

    /// Resolves a LogFont ([MS-EMF] §2.2.13) to a `ResolvedFont`, appending one
    /// coalesced `fontSubstituted` entry per requested family that had to be
    /// remapped.
    static func resolve(_ logFont: LogFont, substitutions: [FontSubstitution] = [], log: inout EMFRenderLog) -> ResolvedFont {
        let styled = resolveFamily(
            logFont.faceName,
            bold: logFont.weight >= 600,
            italic: logFont.italic != 0,
            substitutions: substitutions,
            log: &log
        )

        return ResolvedFont(
            base: styled,
            // The requested face, capped and trimmed exactly as `resolveFamily`
            // caps it, so the E1 lift carries what the file asked for (S-L5 bound).
            requestedFamily: String(logFont.faceName.prefix(requestedFamilyLengthLimit))
                .trimmingCharacters(in: .whitespaces),
            logicalHeight: logFont.height,
            escapementTenths: logFont.escapement,
            underline: logFont.underline != 0,
            strikeOut: logFont.strikeOut != 0
        )
    }

    /// Resolves a family name plus bold/italic to a base CTFont at `nominalSize`,
    /// reusing the SAME substitution table and trait application as the GDI
    /// LOGFONT path — the EMF+ text records (DrawString/DrawDriverString) carry an
    /// EmfPlusFont with a family name and FontStyle flags ([MS-EMFPLUS] §2.1.2.4)
    /// rather than a LOGFONT, but must resolve identically (primer §6: no parallel
    /// font stack). Substitutions are logged (coalesced) exactly as the GDI path.
    /// The caller sizes the returned base to the device point size at draw time.
    static func resolveFamily(_ family: String, bold: Bool, italic: Bool, substitutions: [FontSubstitution] = [], log: inout EMFRenderLog) -> CTFont {
        // Cap the file-supplied family before trimming, normalising, or any lookup:
        // `prefix(n)` walks at most `n` graphemes, so even a pathological face name is
        // bounded work from here down (S-L5). Covers the LOGFONT path (via `resolve`)
        // and the EMF+ family path, which both land here.
        let requested = String(family.prefix(requestedFamilyLengthLimit))
            .trimmingCharacters(in: .whitespaces)
        let fallback: (font: CTFont, substitute: String?) = (emergencyFallbackFont, nil)
        let lookup = FontLookupQueue.run(fallback: fallback) { () -> (font: CTFont, substitute: String?) in
            let base = baseFont(forFamily: requested, substitutions: substitutions)
            return (applyTraits(to: base.font, bold: bold, italic: italic), base.substitute)
        }
        if let substitute = lookup.substitute {
            log.noteFontSubstituted(requested: requested, used: substitute)
        }
        return lookup.font
    }

    // MARK: - Font creation

    /// Creates a font by family/PostScript name at `nominalSize` WITHOUT font
    /// auto-activation. Plain `CTFontCreateWithName` asks the system's font
    /// providers whether they can supply a missing family, a synchronous XPC
    /// round trip per lookup. The family name comes straight from the file
    /// (§8: hostile input), so a file must not be able to trigger font
    /// downloads. Resolution among installed fonts is unchanged.
    private static func font(named name: String) -> CTFont {
        CTFontCreateWithNameAndOptions(name as CFString, nominalSize, nil, .preventAutoActivation)
    }

    // MARK: - Family resolution

    /// The base CTFont for a requested family name, at `nominalSize`, applying
    /// the substitution table on a CoreText miss. Returns the family used when
    /// it had to substitute, so the caller can log it (the log is caller-owned
    /// and never crosses to the lookup queue). Runs on `FontLookupQueue`.
    private static func baseFont(forFamily requested: String, substitutions: [FontSubstitution]) -> (font: CTFont, substitute: String?) {
        // An empty face name goes straight to the default (font mapper choice).
        guard !requested.isEmpty else {
            return (font(named: defaultFamily), defaultFamily)
        }

        // Direct try. If CoreText returns a font whose family matches the
        // request, use it as-is (Arial, Times New Roman, Tahoma, … resolve
        // directly on macOS; Calibri resolves too when Office is installed). An
        // installed family is therefore never substituted.
        let direct = font(named: requested)
        if familyMatches(direct, requested) {
            return (direct, nil)
        }

        // Miss: CoreText silently substituted. Consult the user table FIRST
        // (S1b RenderOptions). A matching entry whose replacement itself resolves
        // wins; a missing replacement falls through to the built-in table below.
        if let userReplacement = userSubstitution(for: requested, in: substitutions) {
            let candidate = font(named: userReplacement)
            if familyMatches(candidate, userReplacement) {
                return (candidate, userReplacement)
            }
        }

        // Built-in table.
        let replacement = substitution(for: requested)
        return (font(named: replacement), replacement)
    }

    /// The first user substitution whose requested family matches `requested`
    /// (case- and space-insensitively), or nil. Bounded over the caller-supplied
    /// list: at most `userSubstitutionLimit` entries are read, and an entry whose
    /// requested or replacement name exceeds `familyNameLengthLimit` characters,
    /// or whose replacement is blank, is skipped.
    private static func userSubstitution(for requested: String, in substitutions: [FontSubstitution]) -> String? {
        let key = normalise(requested)
        for entry in substitutions.prefix(userSubstitutionLimit) {
            // The cheap UTF-8 byte count (O(1) for a native string) gates the O(n)
            // grapheme `.count`: utf8.count > 4·limit guarantees count > limit, so an
            // over-long name is rejected without walking it (S-L5).
            guard entry.requestedFamily.utf8.count <= familyNameLengthLimit * 4,
                  entry.replacementFamily.utf8.count <= familyNameLengthLimit * 4,
                  entry.requestedFamily.count <= familyNameLengthLimit,
                  entry.replacementFamily.count <= familyNameLengthLimit else { continue }
            guard normalise(entry.requestedFamily) == key else { continue }
            let replacement = entry.replacementFamily.trimmingCharacters(in: .whitespaces)
            if !replacement.isEmpty { return replacement }
        }
        return nil
    }

    /// The substitution-table target for a Windows family CoreText could not
    /// resolve. CJK families (MS Gothic/Mincho, SimSun, Batang) map to the
    /// default and rely on CTLine's font cascade to supply CJK glyphs from a
    /// system fallback (primer §6). Matched case- and space-insensitively.
    private static func substitution(for requested: String) -> String {
        switch normalise(requested) {
        case "calibri":
            return "Helvetica Neue"
        case "mssansserif", "microsoftsansserif":
            return "Helvetica"
        case "tahoma":
            return "Helvetica Neue"
        default:
            // MS Gothic / MS Mincho / SimSun / Batang and everything else:
            // the default face; CTLine font cascading covers CJK glyphs.
            return defaultFamily
        }
    }

    /// True when `font`'s family name equals `requested` ignoring case and
    /// whitespace — the CoreText-miss detector (CoreText returns a fallback
    /// with a DIFFERENT family name when the requested one is absent).
    private static func familyMatches(_ font: CTFont, _ requested: String) -> Bool {
        let family = CTFontCopyFamilyName(font) as String
        return normalise(family) == normalise(requested)
    }

    private static func normalise(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: - Traits

    /// Applies bold/italic symbolic traits, keeping the base font when the
    /// styled variant does not exist (common — many faces lack a bold-italic).
    private static func applyTraits(to font: CTFont, bold: Bool, italic: Bool) -> CTFont {
        guard bold || italic else { return font }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        // The mask restricts the copy to the traits we set, leaving others
        // untouched. A nil result means the variant is unavailable → keep base.
        return CTFontCreateCopyWithSymbolicTraits(font, nominalSize, nil, traits, traits)
            ?? font
    }

    // MARK: - Sizing (used by the text drawer)

    /// The point size for a resolved font in the space `logicalToDrawSpace`
    /// maps logical units into (the renderer sizes in device space, then a
    /// canvas-fit transform scales device→target uniformly). lfHeight is in
    /// LOGICAL units and scales by that transform's average axis scale (same
    /// approximation family as geometric pen widths, StrokeMapper.averageScale).
    /// Sign convention ([MS-EMF] §2.2.13): NEGATIVE = character (em) height →
    /// point size = |height|; POSITIVE = cell height → em ≈ 0.9 × height (an
    /// approximation — real emitters overwhelmingly write negative heights);
    /// 0 → the 12pt default.
    static func devicePointSize(
        logicalHeight: Int32,
        logicalToTarget logicalToDrawSpace: CGAffineTransform
    ) -> CGFloat {
        let scale = StrokeMapper.averageScale(logicalToDrawSpace)
        let logicalPoints: CGFloat
        if logicalHeight < 0 {
            logicalPoints = CGFloat(-Int(logicalHeight))
        } else if logicalHeight > 0 {
            logicalPoints = 0.9 * CGFloat(Int(logicalHeight))
        } else {
            logicalPoints = defaultHeight
        }
        let sized = logicalPoints * scale
        // A degenerate (zero/negative) result would make CoreText unhappy;
        // floor at 1 device point so text never vanishes to nothing.
        guard sized.isFinite && sized >= 1 else { return max(defaultHeight, 1) }
        // Ceiling: a glyph larger than the canvas is never useful and feeds
        // CoreText an enormous outline-flattening size (the anti-hang for a
        // hostile lfHeight). Normal sizes are far below the cap, so untouched.
        return min(sized, maxDevicePointSize)
    }
}

/// Runs FontMapper's CoreText font-registry lookups (and the CTLine/CTFramesetter
/// typesetting that can trigger cascade/fallback lookups) on one private serial
/// queue instead of the caller's thread.
///
/// On macOS 27.2, when every Swift-concurrency cooperative thread is blocked
/// in a synchronous CoreText font lookup (`CTFontCreateWithName*`, trait
/// variants, and the glyph-cascade a `CTLineCreateWithAttributedString` /
/// `CTFramesetter*` runs for missing glyphs), none of those lookups ever
/// receives its font-service reply and the process deadlocks. The same lookups
/// made from a non-cooperative thread complete normally, even while the whole
/// cooperative pool is blocked. Quick Look's async `providePreview` and the
/// Swift Testing runner both render on that pool, so a saturating burst of text
/// renders could wedge them.
///
/// Dispatch queues run on the workqueue, not the cooperative pool, so the
/// caller blocks on a semaphore while the lookup runs here. Lookups are short
/// and CoreText caches them, so serialising costs microseconds per text object.
/// The body never re-enters FontMapper, so it cannot wait on itself.
///
/// The wait is BOUNDED (`timeout`): if a font-service reply never arrives (a
/// wedged provider, not just a saturated pool) the call returns a pre-created
/// `fallback` and logs it, rather than hanging a sandboxed Quick Look extension
/// forever (§8). The heap `Box` outlives the call, so a late `body` completion
/// writes into it harmlessly.
enum FontLookupQueue {
    private static let queue = DispatchQueue(label: "com.avneetsingh.emfkit.font-lookup", qos: .userInitiated)

    /// The bounded wait for one queued lookup. Healthy CoreText lookups are
    /// microseconds; this only bites when a provider is wedged, where one
    /// substituted font beats an unbounded hang (§8). Overridable per call.
    static let timeout: DispatchTimeInterval = .seconds(5)

    /// Holds a value across the queue hop. CTFont/CTLine are immutable and safe
    /// to use from any thread once created, so `@unchecked` is sound; the heap
    /// box also lets a LATE `body` completion write its result harmlessly after
    /// `run` already returned a fallback.
    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// Launders a non-`Sendable` `body` across the `queue.async` hop. Sound
    /// because `run` blocks on the semaphore until `body` has run (or timed out):
    /// the closure and any CoreText objects it captures (CTFont/CTLine, which are
    /// thread-safe once created) are only ever touched by one thread at a time.
    private final class Work: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// Runs `body` on the private lookup queue (off the cooperative pool),
    /// waiting at most `timeout`. On timeout it returns the pre-created
    /// `fallback` and calls `onTimeout` (which logs to stderr by default), while
    /// the still-running `body` writes into the heap `Box` harmlessly.
    static func run<Value>(
        timeout: DispatchTimeInterval = Self.timeout,
        fallback: Value,
        onTimeout: () -> Void = { Self.noteTimeout() },
        _ body: @escaping () -> Value
    ) -> Value {
        let box = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        let work = Work {
            box.value = body()
            done.signal()
        }
        queue.async { work.run() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            onTimeout()
            return fallback
        }
        // The semaphore orders the queue's write before this read, so the value
        // is present; the fallback only keeps this free of a force-unwrap.
        return box.value ?? fallback
    }

    /// Creates a font on the lookup queue with NO timeout — used ONCE to
    /// pre-create the emergency fallback font itself (`FontMapper
    /// .emergencyFallbackFont`), so even that bootstrap never runs a CoreText
    /// lookup on a cooperative thread. `queue.sync` needs no `Sendable` body
    /// (it runs synchronously); it is called only from caller threads, never
    /// from within a queue block, so it cannot deadlock on reentrancy.
    static func preCreateFont(_ body: () -> CTFont) -> CTFont {
        queue.sync(execute: body)
    }

    /// Reports a lookup timeout to stderr (an operational log, not the render
    /// honesty channel, which this low-level helper cannot reach).
    private static func noteTimeout() {
        FileHandle.standardError.write(Data(
            "EMFKit: a CoreText font lookup exceeded the font-queue timeout; using the pre-created system fallback font (§8 anti-hang).\n".utf8))
    }
}
