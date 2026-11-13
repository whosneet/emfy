import Foundation

// MARK: - Translate-in-place batch mapping (X2c)
//
// Pure, clean-room helpers for the "Translate…" edit: a strict decode of the model's
// translation reply ({"translations":[{"id":N,"text":"…"}]}) and a per-batch
// reconciliation that maps the returned strings back to the EXACT element ids requested,
// rejecting any unknown, duplicate or missing id. The app layer drives the model and the
// width measurement; this file owns only the untrusted-JSON → id-mapping step, so it is
// unit-tested in EMFKit without a model. The reconciled map becomes `setText` ops through
// the EditPlan validator, so a translation runs the SAME preview/confirm/undo path as any
// other edit.
//
// Security (CLAUDE.md §8 / axiom-security): the JSON is untrusted model output. The decode
// is strict (extra fields are ignored, a bad shape throws), every returned id is checked
// against the requested set before use, each string is length-capped, and nothing here
// force-unwraps or does unchecked arithmetic.

/// One id→text pair as the model returned it.
public struct TranslationEntry: Sendable, Equatable, Decodable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// Why reconciling a translation batch failed. ANY problem rejects the WHOLE batch — a
/// partial batch is never applied.
public enum TranslationBatchProblem: Error, Sendable, Equatable {
    /// The reply could not be decoded as the translation JSON.
    case notDecodable(String)
    /// A returned id was not one of the runs requested in this batch.
    case unknownID(Int)
    /// The same id was returned more than once.
    case duplicateID(Int)
    /// A requested run was not returned.
    case missingID(Int)
    /// A translated string exceeds the length cap.
    case textTooLong(id: Int, length: Int, limit: Int)
}

public enum TextTranslation {
    /// The per-run translated-text length cap (matches the EditPlan validator's text cap,
    /// so a reconciled string always passes `EditPlanValidator`).
    public static let maxTextLength = 5000

    /// Strictly decodes `{"translations":[{"id":N,"text":"…"}]}` to the ordered entries,
    /// tolerant of surrounding prose / a code fence and ONE conservative key-quoting repair
    /// (the same approach as `EditPlan.decode`), so a small model's dropped opening quote on
    /// a known key still decodes. Throws `.notDecodable` when the repaired text still won't
    /// decode — nothing is applied on a throw.
    public static func decode(fromJSON json: String) throws -> [TranslationEntry] {
        let slice = EditPlan.extractJSONObject(json) ?? json
        if let entries = try? decodeStrict(slice) { return entries }
        do {
            return try decodeStrict(repairKeyQuoting(slice))
        } catch {
            throw TranslationBatchProblem.notDecodable("\(error)")
        }
    }

    private struct Envelope: Decodable { let translations: [TranslationEntry] }

    private static func decodeStrict(_ json: String) throws -> [TranslationEntry] {
        guard let data = json.data(using: .utf8) else {
            throw TranslationBatchProblem.notDecodable("not utf-8")
        }
        return try JSONDecoder().decode(Envelope.self, from: data).translations
    }

    /// Known translation JSON keys (for the conservative re-quoting repair).
    private static let knownKeys = "translations|id|text"

    /// Re-inserts a missing OPENING quote on a known key that immediately follows `{` or `,`
    /// (e.g. `,text":` → `,"text":`). A correctly-quoted key already has a `"` between the
    /// delimiter and the key letters, so it never matches. Bounded to the known key set; no
    /// other structure is touched. §8: no force-unwrap; safe on untrusted input.
    static func repairKeyQuoting(_ json: String) -> String {
        let pattern = "([,{][\\s]*)(\(knownKeys))\"([\\s]*):"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex ..< json.endIndex, in: json)
        return regex.stringByReplacingMatches(in: json, range: range, withTemplate: "$1\"$2\"$3:")
    }

    /// Reconciles the decoded entries against the ids actually requested in this batch:
    /// every returned id must be requested (else `unknownID`), none repeated (else
    /// `duplicateID`), each within the length cap (else `textTooLong`), and every requested
    /// id present (else `missingID`). Returns the id→text map on success, else the FIRST
    /// problem found — so a partial batch is never half-applied.
    public static func reconcile(
        _ entries: [TranslationEntry], requested: [Int], maxTextLength: Int = maxTextLength
    ) -> Result<[Int: String], TranslationBatchProblem> {
        let requestedSet = Set(requested)
        var map: [Int: String] = [:]
        for entry in entries {
            guard requestedSet.contains(entry.id) else { return .failure(.unknownID(entry.id)) }
            if map[entry.id] != nil { return .failure(.duplicateID(entry.id)) }
            if entry.text.count > maxTextLength {
                return .failure(.textTooLong(id: entry.id, length: entry.text.count, limit: maxTextLength))
            }
            map[entry.id] = entry.text
        }
        for id in requested where map[id] == nil { return .failure(.missingID(id)) }
        return .success(map)
    }
}
