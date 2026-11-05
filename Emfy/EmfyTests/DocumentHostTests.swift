import CoreGraphics
import EMFRender
import Foundation
import Testing

// C3a unit tests for the non-UI document-host logic: the open-routing policy
// (OpenRouting), the fit/safe-area maths (ViewerFit), and the DocumentSession
// load-state machine. Like the C2 suite these compile the shared sources into a
// hostless logic bundle, so no `import Emfy` is needed, and they run on macOS and
// the iOS simulator. `EmfyTests.minimalEMF()` (in EmfyTests.swift) supplies valid
// bytes for the loaded-state case.

// MARK: - OpenRouting

@Suite struct OpenRoutingTests {

    @Test func externalOpenReusesFrontWindowWhenOneExists() {
        #expect(OpenRouting.destination(for: .externalFileOpen, hasOpenWindow: true, supportsMultipleWindows: true) == .frontWindow)
        #expect(OpenRouting.destination(for: .externalFileOpen, hasOpenWindow: true, supportsMultipleWindows: false) == .frontWindow)
    }

    @Test func externalOpenMakesAWindowWhenNoneExists() {
        #expect(OpenRouting.destination(for: .externalFileOpen, hasOpenWindow: false, supportsMultipleWindows: true) == .newWindow)
        // Even where multi-window is unavailable, a cold open must produce a window.
        #expect(OpenRouting.destination(for: .externalFileOpen, hasOpenWindow: false, supportsMultipleWindows: false) == .newWindow)
    }

    @Test func inWindowOpenStaysInTheFrontWindow() {
        #expect(OpenRouting.destination(for: .inWindowOpen, hasOpenWindow: true, supportsMultipleWindows: true) == .frontWindow)
        #expect(OpenRouting.destination(for: .inWindowOpen, hasOpenWindow: false, supportsMultipleWindows: true) == .frontWindow)
    }

    @Test func explicitNewWindowHonoursMultiWindowSupport() {
        #expect(OpenRouting.destination(for: .newWindowCommand, hasOpenWindow: true, supportsMultipleWindows: true) == .newWindow)
        #expect(OpenRouting.destination(for: .openInNewWindow, hasOpenWindow: true, supportsMultipleWindows: true) == .newWindow)
        // On the Duo outer display (no second window) they fall back to the front.
        #expect(OpenRouting.destination(for: .newWindowCommand, hasOpenWindow: true, supportsMultipleWindows: false) == .frontWindow)
        #expect(OpenRouting.destination(for: .openInNewWindow, hasOpenWindow: true, supportsMultipleWindows: false) == .frontWindow)
    }

    @Test func newWindowAffordanceMirrorsSupport() {
        #expect(OpenRouting.offersNewWindow(supportsMultipleWindows: true))
        #expect(!OpenRouting.offersNewWindow(supportsMultipleWindows: false))
    }
}

// MARK: - ViewerFit

@Suite struct ViewerFitTests {

    @Test func fitClampsToActualSizeWhenContentFits() {
        // 100×100 in a 400×400 viewport would fit at 4×, but fit never magnifies.
        let scale = ViewerFit.fitScale(content: CGSize(width: 100, height: 100),
                                       viewport: CGSize(width: 400, height: 400))
        #expect(scale == 1)
    }

    @Test func fitShrinksContentLargerThanViewport() {
        let scale = ViewerFit.fitScale(content: CGSize(width: 800, height: 400),
                                       viewport: CGSize(width: 400, height: 400))
        #expect(abs(scale - 0.5) < 1e-9)   // width is the binding dimension: 400/800
    }

    @Test func safeAreaInsetsReduceTheFitScale() {
        let content = CGSize(width: 1000, height: 1000)
        let viewport = CGSize(width: 500, height: 500)
        let full = ViewerFit.fitScale(content: content, viewport: viewport)
        let barred = ViewerFit.fitScale(content: content, viewport: viewport,
                                        insets: ViewerFit.Insets(top: 100, bottom: 100))
        // Bars eat 200 pt of height, so the picture must fit smaller than full screen.
        #expect(barred < full)
        #expect(abs(full - 0.5) < 1e-9)          // 500/1000
        #expect(abs(barred - 0.3) < 1e-9)        // (500-200)/1000
    }

    @Test func marginReducesTheFitScale() {
        let scale = ViewerFit.fitScale(content: CGSize(width: 1000, height: 1000),
                                       viewport: CGSize(width: 520, height: 520),
                                       margin: 10)
        #expect(abs(scale - 0.5) < 1e-9)   // (520 - 20)/1000
    }

    @Test func degenerateAndNonFiniteInputsReturnMinScale() {
        #expect(ViewerFit.fitScale(content: .zero, viewport: CGSize(width: 100, height: 100), minScale: 0.02) == 0.02)
        #expect(ViewerFit.fitScale(content: CGSize(width: 100, height: 100), viewport: .zero, minScale: 0.02) == 0.02)
        let infinite = CGSize(width: CGFloat.infinity, height: 100)
        #expect(ViewerFit.fitScale(content: infinite, viewport: CGSize(width: 100, height: 100), minScale: 0.02) == 0.02)
    }

    @Test func availableSizeNeverCollapsesBelowOne() {
        let size = ViewerFit.availableSize(viewport: CGSize(width: 50, height: 50),
                                           insets: ViewerFit.Insets(top: 40, leading: 40, bottom: 40, trailing: 40))
        #expect(size.width == 1)
        #expect(size.height == 1)
    }

    @Test func centringInsetCentresSmallContentAndClampsLargeContent() {
        // Content smaller than the viewport is centred: 200 pt slack / 2 = 100 each side.
        let small = ViewerFit.centringInset(content: CGSize(width: 200, height: 200),
                                            viewport: CGSize(width: 400, height: 400),
                                            scale: 1)
        #expect(abs(small.leading - 100) < 1e-9)
        #expect(abs(small.top - 100) < 1e-9)
        // Content larger than the viewport gets no extra inset beyond the safe area.
        let large = ViewerFit.centringInset(content: CGSize(width: 800, height: 800),
                                            viewport: CGSize(width: 400, height: 400),
                                            scale: 1,
                                            insets: ViewerFit.Insets(top: 20, leading: 20, bottom: 20, trailing: 20))
        #expect(large.leading == 20)
        #expect(large.top == 20)
    }
}

// MARK: - DocumentSession

@MainActor
@Suite struct DocumentSessionTests {

    /// A session wired to succeed, failing only if `parse` is overridden.
    private func makeSession(
        resolve: @escaping @MainActor (UUID) async throws -> Data,
        parse: @escaping @Sendable (Data) -> LoadedMetafile? = { try? MetafileLoader.load($0) }
    ) -> DocumentSession {
        DocumentSession(entryID: UUID(), resolve: resolve, parse: parse)
    }

    @Test func startsIdle() {
        let session = makeSession(resolve: { _ in Data() })
        #expect(session.state.kind == .idle)
        #expect(session.loaded == nil)
        #expect(!session.undoManager.canUndo)   // the editing slot is present but unused
    }

    @Test func loadsValidBytesToLoaded() async {
        let session = makeSession(resolve: { _ in EmfyTests.minimalEMF() })
        await session.load()
        #expect(session.state.kind == .loaded)
        #expect(session.loaded != nil)
    }

    @Test func notFoundResolveFails() async {
        let session = makeSession(resolve: { _ in throw RecentsStore.ResolveFailure.notFound })
        await session.load()
        #expect(session.state.kind == .failedNotFound)
        #expect(session.loaded == nil)
    }

    @Test func unavailableResolveFails() async {
        let session = makeSession(resolve: { _ in throw RecentsStore.ResolveFailure.unavailable })
        await session.load()
        #expect(session.state.kind == .failedUnavailable)
    }

    @Test func genericResolveErrorIsTreatedAsTransient() async {
        struct Boom: Error {}
        let session = makeSession(resolve: { _ in throw Boom() })
        await session.load()
        #expect(session.state.kind == .failedUnavailable)
    }

    @Test func resolvedButUnparseableIsUnreadable() async {
        let session = makeSession(resolve: { _ in Data([1, 2, 3]) }, parse: { _ in nil })
        await session.load()
        #expect(session.state.kind == .failedUnreadable)
    }

    @Test func tryAgainRecoversFromTransientFailure() async {
        // First attempt is unavailable; a flipped flag lets the retry succeed.
        final class Gate: @unchecked Sendable { var open = false }
        let gate = Gate()
        let session = makeSession(resolve: { _ in
            if gate.open { return EmfyTests.minimalEMF() }
            throw RecentsStore.ResolveFailure.unavailable
        })
        await session.load()
        #expect(session.state.kind == .failedUnavailable)
        gate.open = true
        await session.load()                 // Try Again
        #expect(session.state.kind == .loaded)
    }

    @Test func failureReasonMapping() {
        #expect(DocumentSession.failureReason(for: RecentsStore.ResolveFailure.notFound) == .notFound)
        #expect(DocumentSession.failureReason(for: RecentsStore.ResolveFailure.unavailable) == .unavailable)
        struct Boom: Error {}
        #expect(DocumentSession.failureReason(for: Boom()) == .unavailable)
    }

    @Test func storeBoundSessionFailsNotFoundForMissingEntry() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyDocHost-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecentsStore(locations: .init(
            supportDirectory: dir.appendingPathComponent("Support", isDirectory: true),
            cachesDirectory: dir.appendingPathComponent("Caches", isDirectory: true)
        ))
        // No entry with this id exists, so the store-bound resolve throws .notFound.
        let session = DocumentSession(entryID: UUID(), store: store)
        await session.load()
        #expect(session.state.kind == .failedNotFound)
    }
}
