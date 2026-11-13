import Foundation
import Testing

// X1b review correction 3: clean-up works on the SAVED file, so with unsaved edits the
// save actions must be blocked (a copy made now would silently drop the user's changes).
// Tests the pure gating rule and the model end-to-end on a fixture with a redundant record.

@Suite struct DrawingCleanupModelTests {

    // MARK: - Pure gating rule

    @Test
    func copyIsOfferableRequiresCopyEquivalenceAndCleanState() {
        // Produced, render-equivalent, no unsaved edits → offerable.
        #expect(DrawingCleanupModel.copyIsOfferable(copyExists: true, guardEquivalent: true, hasUnsavedChanges: false))
        // Unsaved edits block it even when the copy exists and is equivalent.
        #expect(!DrawingCleanupModel.copyIsOfferable(copyExists: true, guardEquivalent: true, hasUnsavedChanges: true))
        // No copy produced.
        #expect(!DrawingCleanupModel.copyIsOfferable(copyExists: false, guardEquivalent: true, hasUnsavedChanges: false))
        // Guard failed or couldn't run.
        #expect(!DrawingCleanupModel.copyIsOfferable(copyExists: true, guardEquivalent: false, hasUnsavedChanges: false))
        #expect(!DrawingCleanupModel.copyIsOfferable(copyExists: true, guardEquivalent: nil, hasUnsavedChanges: false))
    }

    // MARK: - End-to-end dirty-state gating

    @Test @MainActor
    func unsavedChangesBlockBothSaves() async {
        let dirty = DrawingCleanupModel()
        dirty.analyse(data: Self.fixtureEMF(), hasUnsavedChanges: true)
        await waitReady(dirty)
        #expect(dirty.phase == .ready)
        #expect(dirty.hasUnsavedChanges)
        #expect(!dirty.optimisedReady)
        #expect(!dirty.compatibleReady)

        // The same file with a clean state DOES offer the optimised copy.
        let clean = DrawingCleanupModel()
        clean.analyse(data: Self.fixtureEMF(), hasUnsavedChanges: false)
        await waitReady(clean)
        #expect(clean.hasOptimisations)
        #expect(clean.optimisedReady)
    }

    @MainActor
    private func waitReady(_ model: DrawingCleanupModel) async {
        for _ in 0 ..< 100 {
            if model.phase == .ready { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Fixture (an EMF with a rectangle + one unused pen, so an optimised copy exists)

    static func fixtureEMF() -> Data {
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func lei32(_ v: Int32) -> [UInt8] { le32(UInt32(bitPattern: v)) }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func record(_ type: UInt32, _ body: [UInt8]) -> [UInt8] { le32(type) + le32(UInt32(8 + body.count)) + body }
        func color(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [r, g, b, 0] }

        var header: [UInt8] = []
        header += le32(1) + le32(88)
        header += lei32(0) + lei32(0) + lei32(100) + lei32(100)
        header += lei32(0) + lei32(0) + lei32(2645) + lei32(2645)
        header += le32(0x464D4520) + le32(0x00010000)
        header += le32(0) + le32(0)
        header += le16(8) + le16(0)
        header += le32(0) + le32(0) + le32(0)
        header += le32(100) + le32(100) + le32(26) + le32(26)

        var records: [[UInt8]] = [header]
        records.append(record(39, le32(0) + le32(0) + color(40, 90, 200) + le32(0)))             // CreateBrush ih=0
        records.append(record(37, le32(0)))                                                       // SelectObject ih=0
        records.append(record(43, lei32(0) + lei32(0) + lei32(80) + lei32(80)))                   // Rectangle
        records.append(record(38, le32(3) + le32(0) + lei32(1) + lei32(0) + color(0, 0, 0)))      // CreatePen ih=3 (unused)
        records.append(record(14, le32(0) + le32(0) + le32(20)))                                  // EOF

        var bytes = records.flatMap { $0 }
        func patch(_ at: Int, _ v: [UInt8]) { for (i, b) in v.enumerated() { bytes[at + i] = b } }
        patch(48, le32(UInt32(bytes.count)))
        patch(52, le32(UInt32(records.count)))
        return Data(bytes)
    }
}
