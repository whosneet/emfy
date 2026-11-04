import CoreGraphics
import EMFRender
import SwiftUI
import UIKit

/// The Photos-style viewer: the drawing full-bleed on a white page, pinch/pan
/// zoom that stays crisp at every level, tap-to-toggle chrome (the background
/// goes black with the bars hidden), a transient zoom pill, a dismissible
/// partial-support banner, and a file-details inspector. Built to the approved
/// iPhone-Viewer / iPhone-Viewer-Immersive / iPhone-Info / iPad-Viewer-Inspector
/// mockups, and to the iPhone Duo rules (system-managed bars; the pill and
/// banner displaced clear of the fold and inner camera).
struct MetafileViewerScreen: View {
    @Environment(RecentsStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entryID: UUID

    @State private var phase: Phase = .loading
    @State private var controller = MetafileZoomController()

    @State private var chromeHidden = false
    @State private var showInspector = false
    @State private var bannerDismissed = false
    @State private var pillVisible = false
    @State private var pillHideTask: Task<Void, Never>?
    @State private var viewerWidth: CGFloat = 0
    @AccessibilityFocusState private var a11yFocus: ViewerA11yFocus?

    private enum Phase {
        case loading
        case loaded(LoadedMetafile)
        case unrenderable
        case failed
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()
            viewerLayout
        }
        .navigationTitle(entry?.baseName ?? "Metafile")
        .navigationBarTitleDisplayMode(.inline)
        .metafileNavigationSubtitle(subtitle)
        .toolbar { bottomBar }
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar(chromeHidden ? .hidden : .visible, for: .bottomBar)
        .statusBarHidden(chromeHidden)
        .overlay(alignment: .top) { topOverlays }
        // File details as a sheet at compact width (iPhone, Duo outer, Split View
        // halves). At regular width (iPad, Duo inner) the details are a trailing
        // column inside `viewerLayout`. SwiftUI's own `.inspector` is NOT used:
        // applied to a NavigationStack-pushed view it pops the stack, at both
        // compact and regular width — so a hand-placed column + sheet gives the
        // same adaptive UX without breaking navigation.
        .sheet(isPresented: compactSheetBinding) { inspectorContent }
        .background(keyboardCommands)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    viewerWidth = width
                }
            }
        }
        .task(id: entryID) { await load() }
        .onChange(of: controller.isZooming) { _, zooming in
            updatePill(zooming: zooming)
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            // Resizing to compact (Split View, Duo close) must not leave an open
            // column turning into an auto-popping sheet — close it.
            if newValue == .compact { showInspector = false }
        }
        .onChange(of: showBanner) { _, shown in
            if shown, let message = partialMessage {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .onDisappear { pillHideTask?.cancel() }
    }

    private var backgroundColor: Color {
        chromeHidden ? .black : Color(.systemGroupedBackground)
    }

    /// Mirrors `showInspector` only at compact width, so the sheet never fights
    /// the regular-width trailing column.
    private var compactSheetBinding: Binding<Bool> {
        Binding(
            get: { !isRegularWidth && showInspector },
            set: { showInspector = $0 }
        )
    }

    // MARK: - Layout (drawing, plus a trailing details column at regular width)

    /// The trailing column width: ≤ 340 pt and ≤ 40% of the viewer, so it never
    /// crowds the drawing in a narrow regular-width window (iPad Split View).
    private var inspectorColumnWidth: CGFloat {
        viewerWidth > 0 ? min(340, viewerWidth * 0.4) : 340
    }

    @ViewBuilder
    private var viewerLayout: some View {
        HStack(spacing: 0) {
            drawingLayer
            if isRegularWidth, showInspector {
                Divider().ignoresSafeArea()
                inspectorContent
                    .frame(width: inspectorColumnWidth)
                    .transition(.move(edge: .trailing))
            }
        }
    }

    @ViewBuilder
    private var drawingLayer: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let model):
            ZoomableMetafileView(
                prepared: model.prepared,
                naturalSize: model.displaySize,
                displayScale: displayScale,
                drawingLabel: "Drawing: \(entry?.baseName ?? "Metafile")",
                controller: controller,
                reduceMotion: reduceMotion,
                chromeHidden: chromeHidden,
                onSingleTap: { toggleChrome() }
            )
            .ignoresSafeArea()
        case .unrenderable:
            message("This drawing couldn’t be rendered.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            message("Emfy couldn’t open this file. It may have been moved, deleted, or changed.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String) -> some View {
        ContentUnavailableView {
            Label("Can’t show this file", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        }
    }

    // MARK: - Bottom toolbar (system-managed; one glass capsule)

    // Fit and Info are grouped so the system renders them as a single glass
    // capsule (the mockup), and on iPhone Duo they move to the side vertical bar
    // together. `.visibilityPriority(.high)` (gated) keeps the pair in the bar
    // longest when the outer display overflows. Share is NOT here yet — I3 adds
    // it; no dead items (dead items would waste a vertical-bar slot on Duo).
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItemGroup(placement: .bottomBar) {
                fitButton
                infoButton
            }
            .visibilityPriority(.high)
        } else {
            ToolbarItemGroup(placement: .bottomBar) {
                fitButton
                infoButton
            }
        }
    }

    private var fitButton: some View {
        Button {
            controller.fit()
        } label: {
            Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
        }
    }

    private var infoButton: some View {
        Button {
            toggleInspector()
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .accessibilityAddTraits(showInspector ? [.isSelected] : [])
        .accessibilityFocused($a11yFocus, equals: .infoButton)
    }

    // Keyboard shortcuts stay registered regardless of chrome visibility (a
    // hidden toolbar deregisters its items' shortcuts), so iPad gets
    // ⌘+/⌘−/⌘0/⌘1/⌘I whether the bars are shown or not. "Zoom In" is registered
    // exactly once (no duplicate in the shortcut HUD). Each is hidden from
    // VoiceOver — a shortcut-carrying button stays in the accessibility tree
    // unless the leaf itself is hidden.
    private var keyboardCommands: some View {
        ZStack {
            shortcutButton("Zoom In", "+") { controller.zoomIn() }
            shortcutButton("Zoom Out", "-") { controller.zoomOut() }
            shortcutButton("Fit", "0") { controller.fit() }
            shortcutButton("Actual Size", "1") { controller.actualSize() }
            shortcutButton("Info", "i") { toggleInspector() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func shortcutButton(_ title: String, _ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: .command)
            .accessibilityHidden(true)
    }

    // MARK: - Top overlays (pill + banner), displaced clear of the Duo fold

    @ViewBuilder
    private var topOverlays: some View {
        GeometryReader { proxy in
            let regions = DuoRegions.active(in: proxy)
            let width = proxy.size.width
            let xOffset = DuoRegions.centredOverlayXOffset(viewWidth: width, division: regions.division)
            // Constrain overlays to the larger side of the fold (minus a margin)
            // so Details and X never cross the division when offset (D2).
            let sideWidth = DuoRegions.largerSideWidth(viewWidth: width, division: regions.division)
            let topInset = DuoRegions.overlayTopInset(base: 8, occlusion: regions.occlusion, division: regions.division, viewWidth: width)
            VStack(spacing: 8) {
                if pillVisible {
                    zoomPill
                        .offset(x: xOffset)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                if showBanner, let message = partialMessage {
                    banner(message)
                        .frame(maxWidth: sideWidth - 24)
                        .offset(x: xOffset)
                        .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, topInset)
        }
    }

    private var zoomPill: some View {
        Text("\(zoomPercent)%")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    private var showBanner: Bool {
        !chromeHidden && !bannerDismissed && partialMessage != nil
    }

    private var bannerWarningIcon: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var bannerDetailsButton: some View {
        Button("Details") { openInspectorFromBanner() }
            .font(.callout.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .hoverEffect()
    }

    private var bannerDismissButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { bannerDismissed = true }
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .hoverEffect()
        .accessibilityLabel("Dismiss")
    }

    @ViewBuilder
    private func banner(_ message: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility sizes the message stacks above the buttons so
                // nothing is squeezed off-screen.
                VStack(alignment: .leading, spacing: 10) {
                    Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { bannerWarningIcon }
                        .font(.callout)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        bannerDetailsButton
                        bannerDismissButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    bannerWarningIcon
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    bannerDetailsButton
                    bannerDismissButton
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorContent: some View {
        if let model = loaded, let entry {
            FileInfoInspector(
                entry: entry,
                diagnostics: model.diagnostics,
                naturalSize: model.naturalSize,
                zoomPercent: zoomPercent,
                showZoomRow: isRegularWidth,
                onClose: { closeInspector() },
                headerFocus: $a11yFocus
            )
        } else {
            ContentUnavailableView("No details yet", systemImage: "info.circle")
        }
    }

    // MARK: - Actions

    private func toggleChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            chromeHidden.toggle()
        }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(
                notification: .announcement,
                argument: chromeHidden ? "Controls hidden" : "Controls shown"
            )
        }
    }

    private func toggleInspector() {
        setInspector(!showInspector)
    }

    private func closeInspector() {
        setInspector(false)
    }

    private func openInspectorFromBanner() {
        setInspector(true)
    }

    private func setInspector(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .default) {
            showInspector = open
        }
        // At regular width the inspector is a column: move VoiceOver focus to its
        // header when it opens, and back to Info when it closes.
        if isRegularWidth {
            a11yFocus = open ? .inspectorHeader : .infoButton
        }
    }

    private func updatePill(zooming: Bool) {
        pillHideTask?.cancel()
        if zooming {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.12)) { pillVisible = true }
        } else {
            // Linger briefly, then fade — Reduce Motion hides it without animating.
            pillHideTask = Task {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { pillVisible = false }
            }
        }
    }

    // MARK: - Derived data

    private var loaded: LoadedMetafile? {
        if case .loaded(let model) = phase { return model }
        return nil
    }

    private var partialMessage: String? {
        loaded?.diagnostics.partialSupportMessage
    }

    private var zoomPercent: Int {
        Int((controller.zoom * 100).rounded())
    }

    private var entry: RecentEntry? {
        store.entry(id: entryID)
    }

    private var subtitle: String {
        guard let entry else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file)
        return "\(entry.fullFormatName) · \(size)"
    }

    // MARK: - Loading

    private func load() async {
        phase = .loading
        guard let entry else {
            phase = .failed
            return
        }
        // A bookmark that no longer resolves is a moved/deleted file (.failed);
        // bytes that resolve but won't parse are unrenderable.
        let data: Data
        do {
            data = try await store.resolveData(for: entry)
        } catch {
            if !Task.isCancelled { phase = .failed }
            return
        }
        guard !Task.isCancelled else { return }

        // Run the parse/render off the main thread but cancellably: when the
        // `.task(id:)` is cancelled (the viewer popped or the file changed), the
        // detached task is cancelled too, so its bounded render is skipped and
        // its result never reaches this (gone) view.
        let work = Task.detached(priority: .userInitiated) { () -> LoadedMetafile? in
            try? MetafileLoader.load(data)
        }
        let model = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        phase = model.map(Phase.loaded) ?? .unrenderable
    }
}

extension View {
    /// Applies `navigationSubtitle` on iOS 26+, where it exists; a no-op below.
    @ViewBuilder
    func metafileNavigationSubtitle(_ subtitle: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }

}
