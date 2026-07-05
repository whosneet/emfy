import CoreGraphics
import Foundation
import Testing
@testable import EMFParse
@testable import EMFRender

@Suite("Device context: object table and save/restore")
struct DeviceContextTests {

    private static func makeDC() -> DeviceContext {
        DeviceContext(header: EMFHeader(
            bounds: RectL(left: 0, top: 0, right: 99, bottom: 99),
            frame: RectL(left: 0, top: 0, right: 2646, bottom: 2646),
            recordSignature: 0x464D_4520,
            version: 0x0001_0000,
            bytes: 0,
            records: 0,
            handles: 1,
            nDescription: 0,
            offDescription: 0,
            nPalEntries: 0,
            device: SizeL(cx: 1000, cy: 1000),
            millimeters: SizeL(cx: 250, cy: 250),
            extension1: nil,
            extension2: nil,
            description: nil,
            variant: .extension2
        ))
    }

    private static let red = ColorRef(red: 255, green: 0, blue: 0)
    private static let blue = ColorRef(red: 0, green: 0, blue: 255)

    private static func createBrush(_ index: UInt32, _ color: ColorRef) -> EMFRecordPayload {
        .createBrushIndirect(CreateBrushPayload(ihBrush: index, style: 0, color: color, hatch: 0))
    }

    private static func createSolidPen(_ index: UInt32, width: Int32, _ color: ColorRef) -> EMFRecordPayload {
        .createPen(CreatePenPayload(
            ihPen: index,
            style: 0,   // PS_SOLID
            width: PointL(x: width, y: 0),
            color: color
        ))
    }

    // MARK: - Object table

    @Test("create / select / delete round-trip")
    func createSelectDeleteRoundTrip() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(Self.createBrush(1, Self.red), log: &log)
        _ = dc.apply(Self.createSolidPen(2, width: 3, Self.blue), log: &log)
        #expect(dc.objects.count == 2)

        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        _ = dc.apply(.selectObject(.table(index: 2)), log: &log)
        #expect(dc.state.brush == .solid(Self.red))
        #expect(dc.state.pen == .stroke(ResolvedStroke(
            color: Self.blue, isCosmetic: false, width: 3,
            lineStyle: .solid, cap: .round, join: .round
        )))

        _ = dc.apply(.deleteObject(.table(index: 1)), log: &log)
        _ = dc.apply(.deleteObject(.table(index: 2)), log: &log)
        #expect(dc.objects.isEmpty)
        #expect(log.isClean)
    }

    @Test("delete of a selected handle keeps drawing with the copied value")
    func deleteWhileSelected() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(Self.createBrush(1, Self.red), log: &log)
        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        _ = dc.apply(.deleteObject(.table(index: 1)), log: &log)

        // Selection holds a resolved VALUE, not a table reference.
        #expect(dc.state.brush == .solid(Self.red))
        #expect(dc.objects.isEmpty)
        #expect(log.isClean)

        // Re-selecting the freed slot is the invalid-index case.
        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        #expect(dc.state.brush == .solid(Self.red))
        #expect(log.entries == [.invalidObjectIndex(index: 1)])
    }

    @Test("select of an absent index logs and keeps the current selection")
    func absurdSelect() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        let defaultBrush = dc.state.brush

        _ = dc.apply(.selectObject(.table(index: 4_000_000)), log: &log)

        #expect(dc.state.brush == defaultBrush)
        #expect(log.entries == [.invalidObjectIndex(index: 4_000_000)])
    }

    @Test("table capacity cap: creates at or past the cap are ignored")
    func tableCap() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(Self.createBrush(65_535, Self.red), log: &log)   // last valid slot
        _ = dc.apply(Self.createBrush(65_536, Self.blue), log: &log)  // at the cap: rejected
        _ = dc.apply(Self.createBrush(0, Self.blue), log: &log)       // index 0 reserved

        #expect(dc.objects.count == 1)
        #expect(dc.objects[65_535] == .brush(.solid(Self.red)))
        #expect(log.entries == [
            .objectTableFull(index: 65_536),
            .invalidObjectIndex(index: 0),
        ])
    }

    @Test("stock objects resolve to built-in values")
    func stockResolution() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(.selectObject(.stock(.nullBrush)), log: &log)
        #expect(dc.state.brush == ResolvedBrush.none)

        _ = dc.apply(.selectObject(.stock(.ltGrayBrush)), log: &log)
        #expect(dc.state.brush == .solid(ColorRef(red: 0xC0, green: 0xC0, blue: 0xC0)))

        _ = dc.apply(.selectObject(.stock(.blackPen)), log: &log)
        #expect(dc.state.pen == .stroke(ResolvedStroke(
            color: ColorRef(red: 0, green: 0, blue: 0),
            isCosmetic: true, width: 0,
            lineStyle: .solid, cap: .round, join: .round
        )))

        _ = dc.apply(.selectObject(.stock(.nullPen)), log: &log)
        #expect(dc.state.pen == ResolvedPen.none)
        #expect(log.isClean)
    }

    @Test("palette/unknown stock selections log and change nothing (pen/brush)")
    func unsupportedStock() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        let penBefore = dc.state.pen
        let brushBefore = dc.state.brush

        // Stock FONTs (phase 4) resolve to the system font — tested separately;
        // here palette/undefined stocks and a stock-named DELETEOBJECT are the
        // ones that still change no pen/brush and log.
        _ = dc.apply(.selectObject(.stock(.defaultPalette)), log: &log)
        _ = dc.apply(.selectObject(.stock(.unknownStock(0x8000_0009))), log: &log)
        // DELETEOBJECT must never name a stock object ([MS-EMF] §2.3.8.3).
        _ = dc.apply(.deleteObject(.stock(.blackPen)), log: &log)

        #expect(dc.state.pen == penBefore)
        #expect(dc.state.brush == brushBefore)
        #expect(dc.state.font == nil)     // no font stock selected here
        #expect(log.entries == [
            .unsupportedStockObject(rawValue: 0x8000_000F),
            .unsupportedStockObject(rawValue: 0x8000_0009),
            .unsupportedStockObject(rawValue: 0x8000_0007),
        ])
    }

    // MARK: - Save / restore

    @Test("saveDC/restoreDC(−1) round-trips state including selections")
    func saveRestoreRoundTrip() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(Self.createBrush(1, Self.red), log: &log)
        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        _ = dc.apply(.setPolyFillMode(.winding), log: &log)
        _ = dc.apply(.saveDC, log: &log)

        _ = dc.apply(Self.createBrush(2, Self.blue), log: &log)
        _ = dc.apply(.selectObject(.table(index: 2)), log: &log)
        _ = dc.apply(.setPolyFillMode(.alternate), log: &log)
        _ = dc.apply(.moveToEx(point: PointL(x: 9, y: 9)), log: &log)
        #expect(dc.state.brush == .solid(Self.blue))

        _ = dc.apply(.restoreDC(savedDC: -1), log: &log)
        #expect(dc.state.brush == .solid(Self.red))
        #expect(dc.state.polyFillMode == .winding)
        #expect(dc.state.currentPosition == PointL(x: 0, y: 0))
        // The object table is NOT part of the saved state.
        #expect(dc.objects.count == 2)
        #expect(dc.saveStack.isEmpty)
        #expect(log.isClean)
    }

    @Test("restoreDC(−2) reaches past the top and pops both saved states")
    func restoreTwoDeep() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(Self.createBrush(1, Self.red), log: &log)
        _ = dc.apply(.selectObject(.table(index: 1)), log: &log)
        _ = dc.apply(.saveDC, log: &log)                               // saves red

        _ = dc.apply(Self.createBrush(2, Self.blue), log: &log)
        _ = dc.apply(.selectObject(.table(index: 2)), log: &log)
        _ = dc.apply(.saveDC, log: &log)                               // saves blue

        _ = dc.apply(.selectObject(.stock(.nullBrush)), log: &log)

        _ = dc.apply(.restoreDC(savedDC: -2), log: &log)
        #expect(dc.state.brush == .solid(Self.red))
        #expect(dc.saveStack.isEmpty)
        #expect(log.isClean)
    }

    @Test("restore underflow and non-negative SavedDC log and change nothing")
    func restoreUnderflow() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()
        let before = dc.state

        _ = dc.apply(.restoreDC(savedDC: -1), log: &log)   // empty stack
        _ = dc.apply(.restoreDC(savedDC: 0), log: &log)    // MUST be negative
        _ = dc.apply(.restoreDC(savedDC: 3), log: &log)

        _ = dc.apply(.saveDC, log: &log)
        _ = dc.apply(.restoreDC(savedDC: -2), log: &log)   // deeper than stack

        #expect(dc.state == before)
        #expect(dc.saveStack.count == 1)
        #expect(log.entries == [
            .restoreDCUnbalanced(savedDC: -1),
            .restoreDCUnbalanced(savedDC: 0),
            .restoreDCUnbalanced(savedDC: 3),
            .restoreDCUnbalanced(savedDC: -2),
        ])

        // Int32.min must not trap the negation (§8).
        _ = dc.apply(.restoreDC(savedDC: Int32.min), log: &log)
        #expect(log.entries.count == 5)
    }

    @Test("saveDC stack cap: save 513 drops the save with a log entry")
    func saveStackCap() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        for _ in 0 ..< DeviceContext.saveStackCap {
            _ = dc.apply(.saveDC, log: &log)
        }
        #expect(dc.saveStack.count == 512)
        #expect(log.isClean)

        _ = dc.apply(.saveDC, log: &log)
        #expect(dc.saveStack.count == 512)
        #expect(log.entries == [.saveDCStackOverflow])
    }

    // MARK: - ROP2 (D5)

    @Test("ROP2: copy pen is silent, anything else logs but keeps rendering state")
    func rop2Handling() {
        var dc = Self.makeDC()
        var log = EMFRenderLog()

        _ = dc.apply(.setROP2(rawMode: 0x0D), log: &log)    // R2_COPYPEN
        #expect(log.isClean)

        _ = dc.apply(.setROP2(rawMode: 0x06), log: &log)    // R2_XORPEN
        #expect(dc.state.rop2Raw == 0x06)
        #expect(log.entries == [.unsupportedROP2(rawMode: 0x06, count: 1)])

        // A second occurrence of the same mode COALESCES into the count.
        _ = dc.apply(.setROP2(rawMode: 0x06), log: &log)
        #expect(log.entries == [.unsupportedROP2(rawMode: 0x06, count: 2)])
    }
}
