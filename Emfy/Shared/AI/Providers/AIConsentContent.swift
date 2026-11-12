import Foundation

// MARK: - Consent-screen content and data categories (A2b)
//
// The exact, plain-language data categories a provider may receive, and the builder
// for the consent screen's text. Both the sheet and the stored `AIConsentRecord`
// draw their category list from HERE, so what the user is shown and what is recorded
// can never drift (CLAUDE.md §8 / v3-plan §10.1). Nothing here sends anything; it
// only describes what a send would include, before the user agrees.

/// A category of data a configured provider may receive. The raw value is the exact
/// user-facing sentence shown on the consent screen and stored in the grant.
enum AIDataCategory: String, CaseIterable, Sendable {
    case drawingText = "The drawing’s extracted text, up to a bounded excerpt"
    case formatAndPage = "The drawing’s format and page information"
    case recordCounts = "Counts of the kinds of records the drawing is made of"
    case question = "Your question"
    case titles = "Automatic title and tag generation for your recent drawings"
}

/// Why a provider would receive data — drives which categories the consent screen
/// lists and grants.
enum AIConsentPurpose: Equatable, Sendable {
    /// Describe / Ask / Explain, or a Test connection: the drawing's data and (for Ask)
    /// the question.
    case drawingData
    /// Background automatic titles and tags for recent drawings.
    case titles
}

extension AIConsentPurpose {
    /// The categories granted for this purpose. Titling also sends drawing text, so it
    /// carries the drawing-data categories plus its own distinct titling category.
    var categories: [AIDataCategory] {
        switch self {
        case .drawingData:
            return [.drawingText, .formatAndPage, .recordCounts, .question]
        case .titles:
            return [.drawingText, .formatAndPage, .recordCounts, .titles]
        }
    }

    /// The category strings recorded in the grant.
    var categoryStrings: [String] { categories.map(\.rawValue) }
}

/// The fully-resolved text of the consent screen for one provider and purpose. Pure,
/// so the exact wording is unit-tested.
struct AIConsentSheetContent: Equatable, Sendable {
    /// The provider's display name.
    var providerName: String
    /// The provider's host (e.g. "api.anthropic.com"), or an empty string if unknown.
    var host: String
    /// Exactly what will be sent, in plain language.
    var sent: [String]
    /// What is never sent.
    var neverSent: [String]
    /// The provider's own data policy applies.
    var policyNote: String

    static func make(provider: AIProviderConfig, purpose: AIConsentPurpose) -> AIConsentSheetContent {
        AIConsentSheetContent(
            providerName: provider.displayName,
            host: provider.baseURL.host ?? "",
            sent: purpose.categories.map(\.rawValue),
            neverSent: [
                "The file itself",
                "Any images or pictures in the drawing",
                "Any other files",
                "Your API key (except to this provider, to authenticate)",
            ],
            policyNote: "Once sent, \(provider.displayName)’s own data and privacy policy applies to this data."
        )
    }
}

extension AIConsentStore {
    /// Whether this provider's recorded consent covers a given data category — the
    /// extra gate third-party auto-titling checks on top of the core consent gate.
    func hasCategory(_ providerID: String, _ category: AIDataCategory) -> Bool {
        record(for: providerID)?.categories.contains(category.rawValue) ?? false
    }

    /// Grants consent for a purpose, recording that purpose's exact categories.
    func grant(_ providerID: String, purpose: AIConsentPurpose, date: Date = Date()) {
        grant(providerID, categories: purpose.categoryStrings, date: date)
    }
}
