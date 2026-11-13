import EMFEdit
import Foundation
import Observation

// MARK: - The "Clean up & compatibility" view-model (X1b item 2)
//
// Analyses the open drawing for provably-redundant records and produces two save-a-copy
// candidates — an optimised copy (redundant records removed) and a plain-EMF compatible
// copy (EMF+ comment records stripped, for Office/LibreOffice) — each verified render-
// equivalent to the original before it is offered. All heavy work is off the main actor;
// the view reads the app-typed outputs and presents the exporters.

@MainActor
@Observable
final class DrawingCleanupModel {

    enum Phase: Equatable { case idle, analysing, ready, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var items: [DrawingCleanup.Item] = []
    private(set) var originalByteCount = 0
    private(set) var optimisedByteCount = 0
    private(set) var compatibleByteCount = 0
    private(set) var hasOptimisations = false
    private(set) var hasEMFPlus = false
    private(set) var isDual = false
    /// The render-equivalence verdict for each copy (nil = couldn't render to verify).
    private(set) var optimisedGuard: DrawingCleanupGuard.Result?
    private(set) var compatibleGuard: DrawingCleanupGuard.Result?

    @ObservationIgnored private var optimisedData: Data?
    @ObservationIgnored private var compatibleData: Data?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .analysing }

    /// Whether the optimised copy is safe to offer (produced and render-equivalent).
    var optimisedReady: Bool { optimisedData != nil && (optimisedGuard?.equivalent ?? false) }
    /// Whether the compatible copy is safe to offer.
    var compatibleReady: Bool { compatibleData != nil && (compatibleGuard?.equivalent ?? false) }

    /// Set when a copy was produced but the render check failed or couldn't run — the UI
    /// explains why it can't be offered instead of writing a lossy file.
    var optimisedBlockedReason: String? {
        guard optimisedData != nil, !optimisedReady else { return nil }
        return guardReason(optimisedGuard)
    }
    var compatibleBlockedReason: String? {
        guard compatibleData != nil, !compatibleReady else { return nil }
        return guardReason(compatibleGuard)
    }

    private func guardReason(_ result: DrawingCleanupGuard.Result?) -> String {
        guard let result else { return "Emfy couldn’t render the copy to check it, so it isn’t offered." }
        return String(format: "The copy would change the drawing (%.1f%% of pixels differ), so it isn’t offered.", result.changedFraction * 100)
    }

    /// The verified optimised-copy bytes, or nil when it isn't safe to offer.
    func optimisedCopyBytes() -> Data? { optimisedReady ? optimisedData : nil }
    /// The verified compatible-copy bytes, or nil when it isn't safe to offer.
    func compatibleCopyBytes() -> Data? { compatibleReady ? compatibleData : nil }

    /// Analyses `data` and produces the two verified copies off the main actor.
    func analyse(data: Data) {
        phase = .analysing
        task?.cancel()
        task = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { Self.compute(data: data) }.value
            guard let self, !Task.isCancelled else { return }
            let report = computed.report
            self.items = report.items
            self.originalByteCount = report.originalByteCount
            self.optimisedByteCount = report.optimisedByteCount
            self.compatibleByteCount = report.compatibleByteCount
            self.hasOptimisations = report.hasOptimisations
            self.hasEMFPlus = report.hasEMFPlus
            self.isDual = report.isDual
            self.optimisedData = computed.optimised
            self.compatibleData = computed.compatible
            self.optimisedGuard = computed.optimisedGuard
            self.compatibleGuard = computed.compatibleGuard
            self.phase = .ready
        }
    }

    // MARK: Off-main

    private struct Computed: Sendable {
        let report: DrawingCleanup
        let optimised: Data?
        let compatible: Data?
        let optimisedGuard: DrawingCleanupGuard.Result?
        let compatibleGuard: DrawingCleanupGuard.Result?
    }

    nonisolated private static func compute(data: Data) -> Computed {
        let report = DrawingCleanup(data: data)
        let optimised = report.optimisedCopy(of: data)
        let compatible = report.compatibleCopy(of: data)
        let optimisedGuard = optimised.flatMap { DrawingCleanupGuard.compareRenders(original: data, candidate: $0) }
        let compatibleGuard = compatible.flatMap { DrawingCleanupGuard.compareRenders(original: data, candidate: $0) }
        return Computed(report: report, optimised: optimised, compatible: compatible,
                        optimisedGuard: optimisedGuard, compatibleGuard: compatibleGuard)
    }

    // MARK: Display helpers

    /// A plain-language label for a redundancy kind.
    static func label(for kind: DrawingCleanup.Kind) -> String {
        switch kind {
        case .unusedObject: return "Objects created but never used"
        case .unusedDelete: return "Deletes of unused objects"
        case .redundantStateSet: return "Repeated state settings"
        case .emptySaveRestore: return "Empty save/restore pairs"
        case .emfPlusComment: return "EMF+ data (for the compatible copy)"
        }
    }

    /// A short byte-size string (e.g. "1.2 KB").
    static func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
