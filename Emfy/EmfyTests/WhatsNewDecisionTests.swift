import Foundation
import Testing

/// C3b unit tests for the pure logic: the What's New once-per-version decision and
/// the Open Recent list derivation. No UI, no real UserDefaults — an isolated suite
/// so the stored-version tests never touch the standard domain.
@Suite struct WhatsNewDecisionTests {

    // MARK: - WhatsNew.shouldShow (the owner's literal rule)

    @Test func missingStoredVersionShows() {
        #expect(WhatsNew.shouldShow(lastSeenVersion: nil, currentVersion: "3.1"))
    }

    @Test func sameStoredVersionDoesNotShow() {
        #expect(!WhatsNew.shouldShow(lastSeenVersion: "3.1", currentVersion: "3.1"))
    }

    @Test func changedStoredVersionShows() {
        #expect(WhatsNew.shouldShow(lastSeenVersion: "2.0.2", currentVersion: "3.1"))
        // A downgrade (stored newer than current) is still a change, so it shows.
        #expect(WhatsNew.shouldShow(lastSeenVersion: "3.1", currentVersion: "3.0"))
    }

    // MARK: - shouldShowOnLaunch + recordShown round-trip

    /// A throwaway defaults domain so the test never reads or writes the real one.
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "WhatsNewDecisionTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func firstLaunchShowsThenRecordingSilencesIt() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Nothing stored → show.
        #expect(WhatsNew.shouldShowOnLaunch(defaults: defaults, currentVersion: "3.1", arguments: []))
        // Record the current version, then the same launch decision is silent.
        WhatsNew.recordShown(defaults: defaults, currentVersion: "3.1")
        #expect(!WhatsNew.shouldShowOnLaunch(defaults: defaults, currentVersion: "3.1", arguments: []))
        // A later version shows again.
        #expect(WhatsNew.shouldShowOnLaunch(defaults: defaults, currentVersion: "3.2", arguments: []))
    }

    #if DEBUG
    @Test func resetLaunchArgumentForcesShow() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        WhatsNew.recordShown(defaults: defaults, currentVersion: "3.1")
        #expect(!WhatsNew.shouldShowOnLaunch(defaults: defaults, currentVersion: "3.1", arguments: []))
        // The DEBUG reset argument clears the stored version, so it shows again.
        #expect(WhatsNew.shouldShowOnLaunch(
            defaults: defaults,
            currentVersion: "3.1",
            arguments: [WhatsNew.resetLaunchArgument]
        ))
    }
    #endif

    // MARK: - OpenRecentList derivation

    private func entry(name: String, daysAgo: Double) -> RecentEntry {
        RecentEntry(
            id: UUID(),
            displayName: name,
            formatLabel: "EMF",
            fullFormatName: "Enhanced Metafile",
            byteCount: 10,
            openedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            bookmark: Data([1]),
            thumbnailFileName: nil,
            fileIdentity: "/x/\(name)",
            importedFileName: nil,
            reloadToken: UUID()
        )
    }

    @Test func openRecentReturnsNewestFirstCappedAtTen() {
        // Twelve entries handed in oldest-first, to prove the derivation sorts.
        let entries = (0..<12).reversed().map { entry(name: "f\($0).emf", daysAgo: Double($0)) }
        let items = OpenRecentList.items(from: entries)

        #expect(items.count == OpenRecentList.maximumCount)   // capped at 10
        #expect(items.first?.displayName == "f0.emf")          // most recent (0 days ago)
        #expect(items.last?.displayName == "f9.emf")           // 10th most recent
        // The two oldest never appear.
        #expect(!items.contains { $0.displayName == "f10.emf" })
        #expect(!items.contains { $0.displayName == "f11.emf" })
    }

    @Test func openRecentHandlesFewerThanTen() {
        let entries = [entry(name: "a.emf", daysAgo: 2), entry(name: "b.emf", daysAgo: 0)]
        let items = OpenRecentList.items(from: entries)
        #expect(items.map(\.displayName) == ["b.emf", "a.emf"])
    }
}
