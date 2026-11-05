import Foundation

/// The confirmation policy for removing files from Recents (C4a H3, H2 — owner
/// decision "Offer Save to Files first"). Pure and platform-neutral so the wording
/// and the branch that decides whether a confirmation is even needed are unit-tested
/// without a window.
///
/// The rule (owner): a *received* entry (`importedFileName != nil`) is a file that
/// came from Mail, Messages, an Inbox or tmp, so Emfy copied it into Imported/ and
/// holds the only copy — removing it deletes that copy. So any removal or clear that
/// touches a received entry must confirm first and offer "Save a Copy…". A removal
/// of ordinary, bookmarked entries keeps the instant, undoable removal with no
/// confirmation.
enum RemovalConfirmation {
    /// Which removal the user asked for.
    enum Scope: Equatable, Sendable {
        /// A single entry (a row/tile Remove, or the viewer's Remove from Recents).
        case single
        /// Clear Recents (all entries, or all matching the current filter).
        case clear
    }

    /// The confirmation to present, or the decision not to confirm at all.
    struct Plan: Equatable, Sendable {
        /// When `false` the caller removes immediately (and shows the Undo toast);
        /// when `true` it presents an alert built from the fields below.
        var needsConfirmation: Bool
        var title: String
        var message: String
        /// The destructive button's title ("Remove" or "Clear Recents").
        var destructiveTitle: String
        /// Whether to offer the "Save a Copy…" button.
        var offersSaveCopy: Bool
        /// Whether "Save a Copy…" must export several files (folder export) rather
        /// than a single file.
        var saveCopyIsMultiple: Bool

        /// A confirmation that doesn't ask — the caller removes straight away.
        static let instant = Plan(
            needsConfirmation: false, title: "", message: "",
            destructiveTitle: "Remove", offersSaveCopy: false, saveCopyIsMultiple: false
        )
    }

    /// Decides what to present for a removal.
    ///
    /// - Parameters:
    ///   - scope: single removal vs Clear Recents.
    ///   - receivedCount: how many entries in the removal set are received copies
    ///     (`importedFileName != nil`) — the only files a removal can destroy.
    ///   - totalCount: how many entries the removal touches in all.
    static func plan(scope: Scope, receivedCount: Int, totalCount: Int) -> Plan {
        switch scope {
        case .single:
            // A single ordinary entry is removed instantly (undoable); only a
            // received single entry needs the Save-a-Copy confirmation.
            guard receivedCount > 0 else { return .instant }
            return Plan(
                needsConfirmation: true,
                title: "Remove This File?",
                message: "This file came from Mail, Messages or another app, so Emfy holds the only copy. Removing it deletes that copy. Save a copy first if you want to keep it.",
                destructiveTitle: "Remove",
                offersSaveCopy: true,
                saveCopyIsMultiple: false
            )
        case .clear:
            // Clear always confirms (H2). The wording and the Save-a-Copy offer
            // depend on whether any received copies are among the files.
            if receivedCount == 0 {
                return Plan(
                    needsConfirmation: true,
                    title: "Clear Recents?",
                    message: "This removes every file from your recent list. The files themselves are not deleted.",
                    destructiveTitle: "Clear Recents",
                    offersSaveCopy: false,
                    saveCopyIsMultiple: false
                )
            }
            let many = receivedCount > 1
            let subject = many ? "Some of these files came" : "One of these files came"
            return Plan(
                needsConfirmation: true,
                title: "Clear Recents?",
                message: "\(subject) from Mail, Messages or other apps, so Emfy holds the only copy. Clearing deletes \(many ? "those copies" : "that copy"). Save \(many ? "them" : "it") first if you want to keep \(many ? "them" : "it").",
                destructiveTitle: "Clear Recents",
                offersSaveCopy: true,
                saveCopyIsMultiple: many
            )
        }
    }

    /// Convenience over `plan(scope:receivedCount:totalCount:)` for a single entry,
    /// reading the received flag directly.
    static func plan(forSingleReceived isReceived: Bool) -> Plan {
        plan(scope: .single, receivedCount: isReceived ? 1 : 0, totalCount: 1)
    }
}
