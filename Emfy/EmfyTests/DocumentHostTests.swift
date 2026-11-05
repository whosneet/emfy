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

    // MARK: - External open honours "Open files in" (S1a-4c)

    @Test func externalOpenHonoursTheOpenFilesInSetting() {
        // Front window already shows a file, multi-window platform (Mac / iPad):
        // new-window mode spawns a window, front-window mode selects in place.
        #expect(OpenRouting.externalDestination(openInNewWindow: true, hasOpenWindow: true, frontWindowIsEmpty: false, supportsMultipleWindows: true) == .newWindow)
        #expect(OpenRouting.externalDestination(openInNewWindow: false, hasOpenWindow: true, frontWindowIsEmpty: false, supportsMultipleWindows: true) == .frontWindow)
    }

    @Test func externalOpenFillsAnEmptyFrontWindowEvenInNewWindowMode() {
        // A cold-launch open is delivered to a freshly-spawned empty window; filling
        // it (not spawning beside it) keeps one window, both modes.
        #expect(OpenRouting.externalDestination(openInNewWindow: true, hasOpenWindow: true, frontWindowIsEmpty: true, supportsMultipleWindows: true) == .frontWindow)
        #expect(OpenRouting.externalDestination(openInNewWindow: false, hasOpenWindow: true, frontWindowIsEmpty: true, supportsMultipleWindows: true) == .frontWindow)
    }

    @Test func externalOpenIgnoresNewWindowSettingWithoutMultiWindow() {
        // iPhone / Duo outer display: the setting is hidden and never spawns a window.
        #expect(OpenRouting.externalDestination(openInNewWindow: true, hasOpenWindow: true, frontWindowIsEmpty: false, supportsMultipleWindows: false) == .frontWindow)
    }

    @Test func externalOpenMakesAWindowOnColdLaunchRegardlessOfSetting() {
        #expect(OpenRouting.externalDestination(openInNewWindow: false, hasOpenWindow: false, frontWindowIsEmpty: true, supportsMultipleWindows: true) == .newWindow)
        #expect(OpenRouting.externalDestination(openInNewWindow: true, hasOpenWindow: false, frontWindowIsEmpty: true, supportsMultipleWindows: true) == .newWindow)
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

    // MARK: - Mac clip-view centring (C4b review #1)

    @Test func centeredClipOriginCentresSmallPageInUnobscuredRegion() {
        let content = CGSize(width: 400, height: 300)
        let bounds = CGSize(width: 1000, height: 800)
        // No insets: the page centre lands at the viewport centre.
        let o0 = ViewerFit.centeredClipOrigin(proposed: .zero, content: content, bounds: bounds, insets: .zero)
        #expect(abs((content.width / 2 - o0.x) - bounds.width / 2) < 1e-9)

        // A 260 pt leading inset (the macOS-26 floating sidebar): the page centres in
        // [260, 1000] — i.e. the detail pane — so its centre appears at 630, and it
        // moves RIGHT (origin more negative), not left (the review #1 sign bug).
        let sidebar = ViewerFit.Insets(leading: 260)
        let o1 = ViewerFit.centeredClipOrigin(proposed: .zero, content: content, bounds: bounds, insets: sidebar)
        let docCentreOnScreen = content.width / 2 - o1.x
        #expect(abs(docCentreOnScreen - (260 + bounds.width) / 2) < 1e-9)   // 630
        #expect(o1.x < o0.x)                                                // shifted right, clear of the sidebar
    }

    @Test func centeredClipOriginHonoursTopInsetOnNonFlippedAxis() {
        let content = CGSize(width: 400, height: 300)
        let bounds = CGSize(width: 1000, height: 800)
        // A 52 pt top (toolbar) inset occludes the high-y edge; the page centres in
        // the lower [0, 748] of the visual height.
        let o = ViewerFit.centeredClipOrigin(proposed: .zero, content: content, bounds: bounds, insets: ViewerFit.Insets(top: 52))
        let docCentreFromBottom = content.height / 2 - o.y
        #expect(abs(docCentreFromBottom - (bounds.height - 52) / 2) < 1e-9)   // 374
    }

    @Test func centeredClipOriginKeepsProposedForLargerPage() {
        let content = CGSize(width: 2000, height: 1600)   // larger than the viewport on both axes
        let bounds = CGSize(width: 1000, height: 800)
        let proposed = CGPoint(x: 123, y: 456)
        let o = ViewerFit.centeredClipOrigin(
            proposed: proposed, content: content, bounds: bounds,
            insets: ViewerFit.Insets(top: 52, leading: 260)
        )
        #expect(o == proposed)   // a zoomed page scrolls freely; the origin is untouched
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

// MARK: - DocumentSession reload serialisation + keep-loaded (M4)

/// A mutable, Sendable holder so a test can change what `resolve` returns between a
/// first load and a keep-loaded reload.
private final class ResolveBox: @unchecked Sendable {
    var result: Result<Data, Error>
    init(_ data: Data) { result = .success(data) }
    func get() throws -> Data { try result.get() }
}

@MainActor
@Suite struct DocumentSessionReloadTests {

    @Test func identicalContentReloadKeepsModelAndDoesNotReset() async {
        let data = EmfyTests.minimalEMF()
        let box = ResolveBox(data)
        let session = DocumentSession(entryID: UUID(), resolve: { _ in try box.get() })
        await session.load()
        #expect(session.state.kind == .loaded)
        #expect(session.modelInstallCount == 1)

        await session.reloadNow()                 // same bytes
        #expect(session.state.kind == .loaded)
        #expect(session.modelInstallCount == 1)   // no swap: the zoom survives
    }

    @Test func changedContentReloadInstallsANewModel() async {
        let box = ResolveBox(EmfyTests.minimalEMF(width: 100, height: 100))
        let session = DocumentSession(entryID: UUID(), resolve: { _ in try box.get() })
        await session.load()
        #expect(session.modelInstallCount == 1)

        box.result = .success(EmfyTests.minimalEMF(width: 240, height: 120))
        await session.reloadNow()
        #expect(session.state.kind == .loaded)
        #expect(session.modelInstallCount == 2)   // new content: a fresh model
    }

    @Test func transientFailureDuringReloadKeepsTheLoadedModel() async {
        let box = ResolveBox(EmfyTests.minimalEMF())
        let session = DocumentSession(entryID: UUID(), resolve: { _ in try box.get() })
        await session.load()
        #expect(session.state.kind == .loaded)

        box.result = .failure(RecentsStore.ResolveFailure.unavailable)
        await session.reloadNow()
        #expect(session.state.kind == .loaded)    // the good render stays on screen
        #expect(session.modelInstallCount == 1)
    }

    @Test func midWriteUnreadableDuringReloadKeepsTheLoadedModel() async {
        let box = ResolveBox(EmfyTests.minimalEMF())
        let session = DocumentSession(entryID: UUID(), resolve: { _ in try box.get() })
        await session.load()
        #expect(session.state.kind == .loaded)

        box.result = .success(Data([1, 2, 3]))    // a partial file that won't parse
        await session.reloadNow()
        #expect(session.state.kind == .loaded)     // keep the last good model
        #expect(session.modelInstallCount == 1)
    }

    @Test func notFoundDuringReloadFailsThrough() async {
        let box = ResolveBox(EmfyTests.minimalEMF())
        let session = DocumentSession(entryID: UUID(), resolve: { _ in try box.get() })
        await session.load()
        box.result = .failure(RecentsStore.ResolveFailure.notFound)
        await session.reloadNow()
        #expect(session.state.kind == .failedNotFound)   // a gone file is surfaced
    }

    @Test func theLatestLoadWinsWhenAnOlderOneFinishesLast() async {
        let a = EmfyTests.minimalEMF(width: 100, height: 100)
        let b = EmfyTests.minimalEMF(width: 240, height: 120)
        let box = ResolveBox(a)
        // The first load (a) resolves slowly; the reload (b) resolves at once, so the
        // older, slower load finishes last and must be discarded by the generation
        // guard rather than overwriting b.
        let session = DocumentSession(entryID: UUID(), resolve: { _ in
            let data = try box.get()
            if data == a { try? await Task.sleep(for: .milliseconds(150)) }
            return data
        })
        async let first: Void = session.load()
        try? await Task.sleep(for: .milliseconds(30))   // let the slow load enter resolve
        box.result = .success(b)
        await session.reloadNow()
        await first
        #expect(session.state.kind == .loaded)
        #expect(session.modelInstallCount == 1)          // only b was installed
    }
}
