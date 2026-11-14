import Foundation

// MARK: - Per-provider consent (A2a)
//
// An explicit per-provider consent gate comes before any drawing leaves the
// device (v3-plan §10.1 / CLAUDE.md §8). This store records, per provider id,
// whether consent was granted, when, and exactly which data categories the user
// agreed to send. The UI (A2b) presents the consent screen and calls `grant`;
// the CORE refuses to send without a grant it can prove (`AIConsentGrant`).
//
// The record is not a secret (no key, no drawing content), so it persists in
// UserDefaults. Keys do NOT: they live in the Keychain.

/// What was consented to, for one provider.
struct AIConsentRecord: Codable, Sendable, Equatable {
    var granted: Bool
    var date: Date
    /// The exact data categories the user agreed may be sent (e.g. the drawing's
    /// text, its structure). Shown back to the user and stored for the audit.
    var categories: [String]
}

/// A proof of consent that only `AIConsentStore` can mint, and only when consent
/// is actually recorded. A provider client cannot be driven without one, so the
/// consent gate cannot be bypassed: `AIConsentGrant` has no public initialiser,
/// and the only way to obtain it is `AIConsentStore.authorize`.
struct AIConsentGrant: Sendable, Equatable {
    /// The provider the grant is for.
    let providerID: String
    // `fileprivate` so no code outside this file can forge a grant.
    fileprivate init(providerID: String) { self.providerID = providerID }
}

/// Records and checks per-provider consent. Backed by an injectable
/// `UserDefaults` so tests use an ephemeral suite.
struct AIConsentStore: Sendable {
    // `UserDefaults` is thread-safe but not `Sendable`-annotated; the store holds
    // only a reference to it and never mutates the reference.
    nonisolated(unsafe) private let defaults: UserDefaults
    private static let keyPrefix = "com.avneetsingh.emfy.ai.consent."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ providerID: String) -> String { Self.keyPrefix + providerID }

    /// The recorded consent for a provider, or nil if never granted.
    func record(for providerID: String) -> AIConsentRecord? {
        guard let data = defaults.data(forKey: key(providerID)),
              let record = try? JSONDecoder().decode(AIConsentRecord.self, from: data) else {
            return nil
        }
        return record.granted ? record : nil
    }

    /// Whether consent is currently granted for a provider.
    func isGranted(_ providerID: String) -> Bool { record(for: providerID) != nil }

    /// Grants consent for a provider, MERGING the agreed categories into any already
    /// recorded for it (S-4). Granting one purpose must not silently drop categories a
    /// previous purpose approved — e.g. approving background titling after Ask must
    /// keep the "your question" category Ask relies on. Order is preserved: existing
    /// categories first, then any newly-agreed ones not already present.
    func grant(_ providerID: String, categories: [String], date: Date = Date()) {
        var merged = record(for: providerID)?.categories ?? []
        for category in categories where !merged.contains(category) {
            merged.append(category)
        }
        let record = AIConsentRecord(granted: true, date: date, categories: merged)
        if let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: key(providerID))
        }
    }

    /// Revokes (deletes) consent for a provider.
    func revoke(_ providerID: String) {
        defaults.removeObject(forKey: key(providerID))
    }

    /// Returns a grant IFF consent is currently recorded, else nil. This is the
    /// ONLY source of an `AIConsentGrant`, so a send cannot happen without consent.
    func authorize(_ providerID: String) -> AIConsentGrant? {
        authorize(providerID, requiring: [])
    }

    /// Returns a grant only when consent is recorded AND every required category is
    /// present in the grant (S-4). This is what enforces consent PER PURPOSE: an Ask
    /// send requires the "your question" category, so a provider consented only for
    /// background titling (which never includes the question) cannot be used to send a
    /// question. `AIConsentStore` is the only minter of `AIConsentGrant`, so the gate
    /// cannot be bypassed.
    func authorize(_ providerID: String, requiring categories: [AIDataCategory]) -> AIConsentGrant? {
        guard let record = record(for: providerID) else { return nil }
        for category in categories where !record.categories.contains(category.rawValue) {
            return nil
        }
        return AIConsentGrant(providerID: providerID)
    }
}
