import Foundation
import Testing
@testable import EMFParse

/// The record-inspector one-line parameter summaries (F5). The formatter is a
/// pure function over the decoded payload, so most cases are asserted directly
/// against a constructed payload; the hostile/truncated cases decode real byte
/// fixtures to prove the summary never traps and reports a malformed verdict.
@Suite("Record inspector summaries")
struct RecordSummaryTests {

    // MARK: - Golden parameter summaries

    @Test("EMR_RECTANGLE bounds")
    func rectangle() {
        let p = EMFRecordPayload.rectangle(box: RectL(left: 10, top: 10, right: 200, bottom: 120))
        #expect(EMFRecordSummary.line(for: p) == "(10,10)–(200,120)")
    }

    @Test("EMR_ELLIPSE bounds")
    func ellipse() {
        let p = EMFRecordPayload.ellipse(box: RectL(left: -5, top: 0, right: 5, bottom: 10))
        #expect(EMFRecordSummary.line(for: p) == "(-5,0)–(5,10)")
    }

    @Test("EMR_LINETO endpoint")
    func lineTo() {
        #expect(EMFRecordSummary.line(for: .lineTo(point: PointL(x: 3, y: 4))) == "→ (3,4)")
    }

    @Test("EMR_MOVETOEX point")
    func moveToEx() {
        #expect(EMFRecordSummary.line(for: .moveToEx(point: PointL(x: 7, y: 8))) == "(7,8)")
    }

    @Test("Poly point count, pluralised")
    func polyCount() {
        let one = EMFRecordPayload.polygon(PolyPointsPayload(
            bounds: RectL(left: 0, top: 0, right: 1, bottom: 1),
            points: [PointL(x: 0, y: 0)]
        ))
        #expect(EMFRecordSummary.line(for: one) == "1 point")
        let three = EMFRecordPayload.polyline(PolyPointsPayload(
            bounds: RectL(left: 0, top: 0, right: 1, bottom: 1),
            points: [PointL(x: 0, y: 0), PointL(x: 1, y: 1), PointL(x: 2, y: 2)]
        ))
        #expect(EMFRecordSummary.line(for: three) == "3 points")
    }

    @Test("PolyPolygon16 reports polys and points")
    func polyPoly() {
        let p = EMFRecordPayload.polyPolygon16(PolyPoly16Payload(
            bounds: RectL(left: 0, top: 0, right: 1, bottom: 1),
            pointCounts: [2, 2],
            points: [PointS(x: 0, y: 0), PointS(x: 1, y: 0), PointS(x: 0, y: 1), PointS(x: 1, y: 1)]
        ))
        #expect(EMFRecordSummary.line(for: p) == "2 polys, 4 points")
    }

    @Test("EMR_SETMAPMODE name")
    func mapMode() {
        #expect(EMFRecordSummary.line(for: .setMapMode(.anisotropic)) == "MM_ANISOTROPIC")
        #expect(EMFRecordSummary.line(for: .setMapMode(.text)) == "MM_TEXT")
        #expect(EMFRecordSummary.line(for: .setMapMode(.unknown(0x42))) == "0x00000042")
    }

    @Test("EMR_SETPOLYFILLMODE name")
    func polyFill() {
        #expect(EMFRecordSummary.line(for: .setPolyFillMode(.alternate)) == "ALTERNATE")
        #expect(EMFRecordSummary.line(for: .setPolyFillMode(.winding)) == "WINDING")
    }

    @Test("EMR_SELECTOBJECT stock and table")
    func selectObject() {
        #expect(EMFRecordSummary.line(for: .selectObject(ObjectHandle(raw: 0x8000_0007))) == "BLACK_PEN")
        #expect(EMFRecordSummary.line(for: .selectObject(ObjectHandle(raw: 0x8000_0005))) == "NULL_BRUSH")
        #expect(EMFRecordSummary.line(for: .selectObject(ObjectHandle(raw: 3))) == "#3")
    }

    @Test("EMR_SETTEXTCOLOR hex")
    func textColor() {
        let c = ColorRef(red: 0xFF, green: 0x80, blue: 0x00)
        #expect(EMFRecordSummary.line(for: .setTextColor(c)) == "#FF8000")
    }

    @Test("EMR_CREATEPEN index and colour")
    func createPen() {
        let p = CreatePenPayload(ihPen: 1, style: 0, width: PointL(x: 2, y: 0),
                                 color: ColorRef(red: 0, green: 0, blue: 0xFF))
        #expect(EMFRecordSummary.line(for: .createPen(p)) == "#1 #0000FF")
    }

    @Test("EMR_EXTTEXTOUTW string and reference")
    func extText() {
        let t = ExtTextPayload(
            graphicsMode: 1, exScale: 0, eyScale: 0,
            reference: PointL(x: 50, y: 60),
            rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0),
            string: "Hello", options: ExtTextOutOptions(rawValue: 0), dx: nil
        )
        #expect(EMFRecordSummary.line(for: .extTextOutW(t)) == "\"Hello\" @ (50,60)")
    }

    @Test("Long text string is truncated with an ellipsis")
    func longText() {
        let longString = String(repeating: "A", count: 200)
        let t = ExtTextPayload(
            graphicsMode: 1, exScale: 0, eyScale: 0,
            reference: PointL(x: 0, y: 0), rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0),
            string: longString, options: ExtTextOutOptions(rawValue: 0), dx: nil
        )
        let summary = EMFRecordSummary.line(for: .extTextOutW(t))
        #expect(summary.hasSuffix("…\" @ (0,0)"))
        // 48 kept characters + the ellipsis.
        #expect(summary.contains(String(repeating: "A", count: EMFRecordSummary.maxStringLength)))
        #expect(!summary.contains(String(repeating: "A", count: EMFRecordSummary.maxStringLength + 1)))
    }

    @Test("Newlines in a text run collapse to spaces")
    func multilineText() {
        let t = ExtTextPayload(
            graphicsMode: 1, exScale: 0, eyScale: 0,
            reference: PointL(x: 1, y: 2), rectangle: RectL(left: 0, top: 0, right: 0, bottom: 0),
            string: "a\nb\tc", options: ExtTextOutOptions(rawValue: 0), dx: nil
        )
        #expect(EMFRecordSummary.line(for: .extTextOutW(t)) == "\"a b c\" @ (1,2)")
    }

    @Test("EMR_SETWORLDTRANSFORM matrix notation")
    func worldTransform() {
        let x = XForm(m11: 2, m12: 0, m21: 0, m22: 1.5, dx: 10, dy: -4)
        #expect(EMFRecordSummary.line(for: .setWorldTransform(x)) == "[2 0 0 1.5] +(10,-4)")
    }

    @Test("Parameterless records summarise to empty")
    func empty() {
        #expect(EMFRecordSummary.line(for: .saveDC) == "")
        #expect(EMFRecordSummary.line(for: .beginPath) == "")
        #expect(EMFRecordSummary.line(for: .endPath) == "")
        #expect(EMFRecordSummary.line(for: .unimplemented(type: 999)) == "")
    }

    // MARK: - Hostile / truncated fixtures never trap

    @Test("A malformed record summarises without trapping")
    func malformedDoesNotTrap() throws {
        // EMR_RECTANGLE (43) needs a 16-byte RectL body; give it 4 bytes and a
        // matching (lying-small) nSize so the decoder returns .malformed.
        let record = FixtureBuilder.record(type: 43, payload: [1, 2, 3, 4])
        let payload = try decodeSingle(record)
        guard case .malformed = payload else {
            Issue.record("expected .malformed, got \(payload)")
            return
        }
        #expect(EMFRecordSummary.line(for: payload).hasPrefix("malformed:"))
    }

    @Test("A lying point count yields a bounded, non-trapping summary")
    func lyingCountDoesNotTrap() throws {
        // EMR_POLYGON16 (86): 16-byte bounds, then a Count of 100000 but only
        // room for a couple of points — the §8-bounded decoder rejects it as
        // malformed rather than allocating, and the summary stays safe.
        var body = FixtureBuilder()
        body.appendInt32(0); body.appendInt32(0); body.appendInt32(1); body.appendInt32(1) // bounds
        body.appendUInt32(100_000)                                                          // lying Count
        body.appendInt16(0); body.appendInt16(0)                                            // one real point
        let record = FixtureBuilder.record(type: 86, payload: body.bytes)
        let payload = try decodeSingle(record)
        // Whatever the verdict, the summary must not trap and must be short.
        let summary = EMFRecordSummary.line(for: payload)
        #expect(summary.count < 80)
    }

    // MARK: - File-level convenience

    @Test("recordSummary(at:) resolves header and body records")
    func fileConvenience() throws {
        // A clean file: header + EMR_RECTANGLE + EOF.
        var fixture = FixtureBuilder()
        fixture.appendBytes(FixtureBuilder.header(
            fixedSize: 108,
            bounds: (0, 0, 640, 480),
            bytesField: 0, recordsField: 3
        ))
        var rectBody = FixtureBuilder()
        rectBody.appendInt32(10); rectBody.appendInt32(10)
        rectBody.appendInt32(200); rectBody.appendInt32(120)
        fixture.appendBytes(FixtureBuilder.record(type: 43, payload: rectBody.bytes))
        fixture.appendBytes(FixtureBuilder.eof())

        let file = try EMFFile.parse(fixture.data)
        #expect(file.recordSummary(at: 0) == "(0,0)–(640,480)")       // header bounds
        #expect(file.recordSummary(at: 1) == "(10,10)–(200,120)")     // the rectangle
        #expect(file.recordSummary(at: 2) == "")                      // EOF (unimplemented)
        #expect(file.recordSummary(at: 99) == "")                     // out of range, safe
    }
}
