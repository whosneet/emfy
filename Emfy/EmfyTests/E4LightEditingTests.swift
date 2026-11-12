import CoreGraphics
import EMFEdit
import Foundation
import SwiftUI
import Testing

// E4 unit tests for iPhone light editing: the pure editor-mode resolver matrix, the
// light-mode "no handles" decision, the colour-apply routing per element kind, one
// undo per pick through `DocumentSession.applyColor`, and the Settings toggle's
// persistence. Shared sources are compiled into this logic bundle, so no window.

// MARK: - Fixtures

private func element(
    id: Int, kind: ElementKind, fill: SceneColor? = nil, stroke: SceneColor? = nil, text: SceneText? = nil
) -> Element {
    var style = SceneStyle()
    if let fill { style.fill = SceneFill(color: fill, evenOdd: false) }
    if let stroke { style.stroke = SceneStroke(color: stroke, isCosmetic: false, width: 2, dash: .solid, cap: .round, join: .round, miterLimit: 10) }
    return Element(
        id: id, kind: kind, geometryDevice: ScenePath(), transform: .identity,
        style: style, text: text, provenance: Provenance(sourceRecordIndices: [])
    )
}

private func textElement(id: Int, colour: SceneColor) -> Element {
    let text = SceneText(
        string: "Hi", fontFamily: "Helvetica", logicalHeight: -24,
        color: colour, referenceLogical: .zero, alignRawValue: 0
    )
    return element(id: id, kind: .text, text: text)
}

// MARK: - Editor-mode resolver

@Suite struct EditorModeResolverTests {

    @Test func iPadIsAlwaysFull() {
        // iPad → full regardless of size class or the toggle.
        for width in [UserInterfaceSizeClass?.none, .some(.compact), .some(.regular)] {
            for toggle in [false, true] {
                #expect(EditorMode.resolve(horizontalSizeClass: width, fullEditorOnIPhone: toggle, idiom: .pad) == .full)
            }
        }
    }

    @Test func iPhoneRegularWidthIsFull() {
        // iPhone Duo / large landscape phone (a regular size class) → full, toggle or not.
        #expect(EditorMode.resolve(horizontalSizeClass: .regular, fullEditorOnIPhone: false, idiom: .phone) == .full)
        #expect(EditorMode.resolve(horizontalSizeClass: .regular, fullEditorOnIPhone: true, idiom: .phone) == .full)
    }

    @Test func iPhoneCompactIsLightUnlessToggled() {
        #expect(EditorMode.resolve(horizontalSizeClass: .compact, fullEditorOnIPhone: false, idiom: .phone) == .light)
        #expect(EditorMode.resolve(horizontalSizeClass: .compact, fullEditorOnIPhone: true, idiom: .phone) == .full)
        // A nil size class on a phone is treated as compact (the conservative default).
        #expect(EditorMode.resolve(horizontalSizeClass: nil, fullEditorOnIPhone: false, idiom: .phone) == .light)
    }

    @Test func lightModeShowsNoHandlesFullModeDoes() {
        #expect(EditorMode.light.showsSelectionHandles == false)
        #expect(EditorMode.full.showsSelectionHandles == true)
    }
}

// MARK: - Colour routing

@Suite struct LightColorRouterTests {

    @Test func channelPerElementKind() {
        // Closed shapes with a fill → fill; a line with a stroke → stroke; text → fill
        // (a run's fill is its glyph colour); an image → skip.
        #expect(LightColorRouter.channel(for: element(id: 1, kind: .rect, fill: SceneColor(red: 0, green: 0, blue: 1))) == .fill)
        #expect(LightColorRouter.channel(for: element(id: 2, kind: .line, stroke: SceneColor(red: 0, green: 0, blue: 0))) == .stroke)
        #expect(LightColorRouter.channel(for: textElement(id: 3, colour: SceneColor(red: 0, green: 0, blue: 0))) == .fill)
        #expect(LightColorRouter.channel(for: element(id: 4, kind: .image)) == .skip)
        #expect(LightColorRouter.channel(for: element(id: 5, kind: .group)) == .skip)
        #expect(LightColorRouter.channel(for: element(id: 6, kind: .passthrough)) == .skip)
    }

    @Test func channelFallsBackToKindWhenNoPaint() {
        // Neither fill nor stroke present: closed kinds → fill, open kinds → stroke.
        #expect(LightColorRouter.channel(for: element(id: 1, kind: .rect)) == .fill)
        #expect(LightColorRouter.channel(for: element(id: 2, kind: .ellipse)) == .fill)
        #expect(LightColorRouter.channel(for: element(id: 3, kind: .polygon)) == .fill)
        #expect(LightColorRouter.channel(for: element(id: 4, kind: .line)) == .stroke)
        #expect(LightColorRouter.channel(for: element(id: 5, kind: .polyline)) == .stroke)
        #expect(LightColorRouter.channel(for: element(id: 6, kind: .path)) == .stroke)
    }

    @Test func commandsSplitFillAndStroke() {
        let colour = SceneColor(red: 0.2, green: 0.4, blue: 0.6)
        let elements = [
            element(id: 1, kind: .rect, fill: SceneColor(red: 1, green: 1, blue: 1)),
            element(id: 2, kind: .line, stroke: SceneColor(red: 0, green: 0, blue: 0)),
            textElement(id: 3, colour: SceneColor(red: 0, green: 0, blue: 0)),
            element(id: 4, kind: .image),
        ]
        let commands = LightColorRouter.commands(for: elements, color: colour)

        var fillIDs: Set<Int>?
        var strokeIDs: Set<Int>?
        for command in commands {
            if case .setFill(let ids, let fill) = command {
                fillIDs = ids
                #expect(fill?.color == colour)
            }
            if case .setStroke(let ids, let stroke) = command {
                strokeIDs = ids
                #expect(stroke?.color == colour)
            }
        }
        // The rect and the text recolour their fill; the line its stroke; the image is skipped.
        #expect(fillIDs == [1, 3])
        #expect(strokeIDs == [2])
    }

    @Test func strokeKeepsExistingWidth() {
        let elements = [element(id: 1, kind: .line, stroke: SceneColor(red: 0, green: 0, blue: 0))]
        let commands = LightColorRouter.commands(for: elements, color: SceneColor(red: 1, green: 0, blue: 0))
        guard case .setStroke(_, let stroke) = commands.first else { Issue.record("expected a setStroke"); return }
        #expect(stroke?.width == 2)   // the element's existing 2-unit stroke width is preserved
    }
}

// MARK: - applyColor undo coalescing

@MainActor
private func makeColourSession(scene: EMFEdit.Scene) -> DocumentSession {
    DocumentSession(
        entryID: UUID(),
        resolve: { _ in Data([0x01]) },
        importScene: { _ in scene },
        documentFileName: { "drawing.emf" },
        autosave: AutosaveController(sleep: { _ in try? await Task.sleep(for: .seconds(86_400)) })
    )
}

private func oneRectScene() -> EMFEdit.Scene {
    let rect = element(id: 0, kind: .rect, fill: SceneColor(red: 1, green: 1, blue: 1))
    let layer = Layer(id: 0, name: "L", elements: [rect])
    let partition = ScenePartition(structural: [], state: [], drawing: [], passthrough: [], unitCount: 0)
    let source = SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 0)
    return EMFEdit.Scene(pageBoundsDevice: CGRect(x: 0, y: 0, width: 100, height: 100), layers: [layer], partition: partition, source: source)
}

@MainActor
@Suite struct ApplyColorTests {

    @Test func sameKeyScrubCoalescesToOneUndo() async {
        let session = makeColourSession(scene: oneRectScene())
        await session.beginEditing()
        let key = SceneCoalescingKey("lightColorPicker")
        session.applyColor(SceneColor(red: 1, green: 0, blue: 0), to: [0], coalescing: key)
        session.applyColor(SceneColor(red: 0, green: 1, blue: 0), to: [0], coalescing: key)
        session.applyColor(SceneColor(red: 0, green: 0, blue: 1), to: [0], coalescing: key)
        // The scrub is one undo step; a single undo returns to the opened scene.
        #expect(session.history?.undoCount == 1)
        session.undoManager.undo()
        #expect(session.debugSceneMatchesOpened())
    }

    @Test func distinctKeysArePerPickUndos() async {
        let session = makeColourSession(scene: oneRectScene())
        await session.beginEditing()
        session.applyColor(SceneColor(red: 1, green: 0, blue: 0), to: [0], coalescing: SceneCoalescingKey("lightSwatch-0"))
        session.applyColor(SceneColor(red: 0, green: 1, blue: 0), to: [0], coalescing: SceneCoalescingKey("lightSwatch-1"))
        // Each discrete pick is its own undo entry.
        #expect(session.history?.undoCount == 2)
    }

    @Test func recolourSetsTheFill() async {
        let session = makeColourSession(scene: oneRectScene())
        await session.beginEditing()
        session.applyColor(SceneColor(red: 1, green: 0, blue: 0), to: [0], coalescing: nil)
        let fill = session.history?.scene.elements.first?.style.fill
        #expect(fill?.color == SceneColor(red: 1, green: 0, blue: 0))
    }
}

// MARK: - Settings toggle persistence

@Suite(.serialized) struct FullEditorToggleTests {

    @MainActor
    @Test func togglePersistsThroughDefaults() throws {
        let name = "EmfyE4Tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        // Default OFF.
        let first = EmfySettings(defaults: defaults, sharedDefaults: defaults)
        #expect(first.fullEditorOnIPhone == false)

        first.fullEditorOnIPhone = true
        // A fresh model over the same suite reads the saved value.
        let second = EmfySettings(defaults: defaults, sharedDefaults: defaults)
        #expect(second.fullEditorOnIPhone == true)
    }
}
