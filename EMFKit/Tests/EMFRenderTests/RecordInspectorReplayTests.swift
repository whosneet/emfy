import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

/// Step-through replay (F5): partial playback "through record N", the
/// checkpointed player, and the DC-state snapshot. Images are compared
/// pixel-exact via `RasterizedImage.pixels`.
@Suite("Record inspector step-through replay")
struct RecordInspectorReplayTests {

    /// A fixture with a red brush rectangle then a blue brush rectangle, each
    /// preceded by its create/select state records. Record indices:
    /// 0 header, 1 brush1, 2 select1, 3 red rect, 4 brush2, 5 select2,
    /// 6 blue rect, 7 EOF.
    private static func twoRectangleFile() throws -> EMFFile {
        var fixture = RenderFixture()
        fixture.createSolidBrush(index: 1, r: 220, g: 0, b: 0)
        fixture.selectObject(1)
        fixture.rectangle(10, 10, 40, 40)
        fixture.createSolidBrush(index: 2, r: 0, g: 0, b: 220)
        fixture.selectObject(2)
        fixture.rectangle(50, 50, 90, 90)
        return try fixture.parsed()
    }

    private static func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let ra = RasterizedImage(a), let rb = RasterizedImage(b) else { return false }
        return ra.width == rb.width && ra.height == rb.height && ra.pixels == rb.pixels
    }

    // MARK: - Through-N equals full render at the last record

    @Test("Partial playback through the last record is pixel-identical to a full render")
    func throughLastEqualsFull() throws {
        let file = try Self.twoRectangleFile()
        let last = file.records.count - 1

        let full = try #require(EMFRenderer.makeImage(file)?.0)
        let partial = try #require(EMFRenderer.makeImage(file, throughRecordIndex: last)?.0)
        #expect(Self.pixelsEqual(full, partial))
    }

    @Test("An out-of-range through index clamps to the last record")
    func throughIndexClamps() throws {
        let file = try Self.twoRectangleFile()
        let full = try #require(EMFRenderer.makeImage(file)?.0)
        let overshoot = try #require(EMFRenderer.makeImage(file, throughRecordIndex: 9_999)?.0)
        #expect(Self.pixelsEqual(full, overshoot))
    }

    // MARK: - A mid record draws a known shape

    @Test("Through the red rectangle: red present, blue absent; through the blue: both")
    func midRecordMatchesReference() throws {
        let file = try Self.twoRectangleFile()

        // Through index 3 (the red rectangle) — only the red rect has drawn.
        let redOnly = try #require(EMFRenderer.makeImage(file, throughRecordIndex: 3)?.0)
        let r1 = try #require(RasterizedImage(redOnly))
        #expect(r1.contains(in: (20, 20, 10, 10)) { $0.r > 150 && $0.g < 100 && $0.b < 100 })
        #expect(!r1.containsBluePixel(in: (60, 60, 20, 20)))

        // Through index 6 (the blue rectangle) — both rects have drawn.
        let both = try #require(EMFRenderer.makeImage(file, throughRecordIndex: 6)?.0)
        let r2 = try #require(RasterizedImage(both))
        #expect(r2.contains(in: (20, 20, 10, 10)) { $0.r > 150 && $0.g < 100 && $0.b < 100 })
        #expect(r2.containsBluePixel(in: (60, 60, 20, 20)))
    }

    @Test("Through the header only, nothing has drawn")
    func throughHeaderIsBlank() throws {
        let file = try Self.twoRectangleFile()
        let blank = try #require(EMFRenderer.makeImage(file, throughRecordIndex: 0)?.0)
        let r = try #require(RasterizedImage(blank))
        #expect(!r.contains(in: (0, 0, 100, 100)) { $0.r < 200 && ($0.g < 200 || $0.b < 200) })
    }

    // MARK: - Checkpoint correctness

    /// A file with many distinctly-placed rectangles so stepping crosses several
    /// checkpoint boundaries. Record i draws a small rect in a deterministic grid
    /// cell, so partial playback through different indices yields different
    /// images.
    private static func gridFile(cells: Int) -> RenderFixture {
        var fixture = RenderFixture()
        fixture.bounds = (0, 0, 199, 199)
        for i in 0 ..< cells {
            let col = Int32(i % 10)
            let row = Int32(i / 10)
            let x = col * 20 + 2
            let y = row * 20 + 2
            let shade = UInt8((i * 11) % 200)
            fixture.createSolidBrush(index: UInt32(i % 8 + 1), r: shade, g: 0, b: 200 - shade)
            fixture.selectObject(UInt32(i % 8 + 1))
            fixture.rectangle(x, y, x + 15, y + 15)
        }
        return fixture
    }

    @Test("A step via a checkpoint equals a step rendered from the start",
          arguments: [8, 15, 23, 30, 12, 4])
    func checkpointEqualsFromStart(index: Int) throws {
        let file = try Self.gridFile(cells: 12).parsed()   // 36 draw records + state

        // A small stride guarantees cached checkpoints exist before `index`.
        let player = MetafilePartialPlayer(file: file, checkpointStride: 4)
        #expect(player.supportsPartial)

        // Prime the checkpoint cache by stepping forward across boundaries.
        for boundary in stride(from: 4, through: file.records.count - 1, by: 4) {
            _ = player.step(throughRecordIndex: boundary)
        }

        // Now a step that resumes from a cached checkpoint must match a
        // from-scratch partial render pixel-for-pixel.
        let viaCheckpoint = try #require(player.step(throughRecordIndex: index).image)
        let fromStart = try #require(EMFRenderer.makeImage(file, throughRecordIndex: index)?.0)
        #expect(Self.pixelsEqual(viaCheckpoint, fromStart))
    }

    // P10: a tiny checkpoint byte budget must still render every step pixel-exact — eviction
    // only forces a re-render from an earlier checkpoint, never a wrong pixel.
    @Test("A tight checkpoint memory budget keeps every step pixel-identical")
    func tightBudgetStaysCorrect() throws {
        let file = try Self.gridFile(cells: 12).parsed()
        // A 1-byte budget caps the cache so at most one small checkpoint can ever be resident;
        // every full-canvas checkpoint is over budget and is dropped.
        let player = MetafilePartialPlayer(file: file, checkpointStride: 4, checkpointMemoryBudget: 1)
        for boundary in stride(from: 4, through: file.records.count - 1, by: 4) {
            _ = player.step(throughRecordIndex: boundary)
        }
        for index in [8, 15, 23, 30, 12, 4] {
            let viaPlayer = try #require(player.step(throughRecordIndex: index).image)
            let fromStart = try #require(EMFRenderer.makeImage(file, throughRecordIndex: index)?.0)
            #expect(Self.pixelsEqual(viaPlayer, fromStart), "mismatch at index \(index)")
        }
    }

    @Test("Stepping backwards through a checkpoint stays correct")
    func steppingBackwards() throws {
        let file = try Self.gridFile(cells: 10).parsed()
        let player = MetafilePartialPlayer(file: file, checkpointStride: 3)
        let last = file.records.count - 1

        // Walk forward to the end (caches checkpoints), then jump back.
        _ = player.step(throughRecordIndex: last)
        for index in [last, 20, 9, 15, 2, last] {
            let viaPlayer = try #require(player.step(throughRecordIndex: index).image)
            let reference = try #require(EMFRenderer.makeImage(file, throughRecordIndex: index)?.0)
            #expect(Self.pixelsEqual(viaPlayer, reference), "mismatch at index \(index)")
        }
    }

    // MARK: - DC state after N

    @Test("Pen colour after a SELECTOBJECT of a created pen")
    func penStateAfterSelect() throws {
        var fixture = RenderFixture()
        // 1 EXTCREATEPEN (geometric, width 3, green), 2 SELECTOBJECT(1), 3 rect.
        fixture.extCreatePen(index: 1, style: 0x0001_0000, width: 3, r: 0, g: 200, b: 0)
        fixture.selectObject(1)
        fixture.rectangle(10, 10, 40, 40)
        let file = try fixture.parsed()

        // Before the select, the default BLACK_PEN is still in force.
        let before = EMFRenderer.playbackState(of: file, throughRecordIndex: 1)
        guard case .stroke(let c0, _, _, _) = before.pen else {
            Issue.record("expected a stroke pen before select"); return
        }
        #expect(c0 == ColorRef(red: 0, green: 0, blue: 0))

        // After the select, the green geometric pen is selected.
        let after = EMFRenderer.playbackState(of: file, throughRecordIndex: 2)
        guard case .stroke(let c1, let cosmetic, let width, _) = after.pen else {
            Issue.record("expected a stroke pen after select"); return
        }
        #expect(c1 == ColorRef(red: 0, green: 200, blue: 0))
        #expect(cosmetic == false)
        #expect(width == 3)
    }

    @Test("Brush colour after a SELECTOBJECT of a created brush")
    func brushStateAfterSelect() throws {
        let file = try Self.twoRectangleFile()
        // After select2 (index 5) the blue brush is current.
        let state = EMFRenderer.playbackState(of: file, throughRecordIndex: 5)
        #expect(state.brush == .solid(ColorRef(red: 0, green: 0, blue: 220)))
    }

    @Test("Map mode and current position reflect the records played")
    func mapModeAndPositionState() throws {
        var fixture = RenderFixture()
        fixture.setMapMode(0x08)          // 1 MM_ANISOTROPIC
        fixture.moveToEx(10, 20)          // 2
        fixture.lineTo(60, 70)            // 3 — advances current position to (60,70)
        let file = try fixture.parsed()

        let afterMove = EMFRenderer.playbackState(of: file, throughRecordIndex: 2)
        #expect(afterMove.mapMode == .anisotropic)
        #expect(afterMove.currentPosition == PointL(x: 10, y: 20))

        let afterLine = EMFRenderer.playbackState(of: file, throughRecordIndex: 3)
        #expect(afterLine.currentPosition == PointL(x: 60, y: 70))
    }

    @Test("Text colour after SETTEXTCOLOR")
    func textColorState() throws {
        var fixture = RenderFixture()
        fixture.setTextColor(r: 10, g: 20, b: 30)   // index 1
        let file = try fixture.parsed()
        let state = EMFRenderer.playbackState(of: file, throughRecordIndex: 1)
        #expect(state.textColor == ColorRef(red: 10, green: 20, blue: 30))
    }

    @Test("SaveDC depth tracked in the DC snapshot")
    func saveDepthState() throws {
        var fixture = RenderFixture()
        fixture.saveDC()   // 1
        fixture.saveDC()   // 2
        fixture.restoreDC(-1)   // 3
        let file = try fixture.parsed()
        #expect(EMFRenderer.playbackState(of: file, throughRecordIndex: 2).saveDepth == 2)
        #expect(EMFRenderer.playbackState(of: file, throughRecordIndex: 3).saveDepth == 1)
    }

    @Test("Clip summary reflects an INTERSECTCLIPRECT")
    func clipState() throws {
        var fixture = RenderFixture()
        fixture.intersectClipRect(10, 10, 50, 50)   // index 1
        let file = try fixture.parsed()
        let state = EMFRenderer.playbackState(of: file, throughRecordIndex: 1)
        if case .region(let count) = state.clip {
            #expect(count >= 1)
        } else {
            Issue.record("expected a clip region, got \(state.clip)")
        }
        // Before the clip record, there is no clip.
        #expect(EMFRenderer.playbackState(of: file, throughRecordIndex: 0).clip == .none)
    }
}
