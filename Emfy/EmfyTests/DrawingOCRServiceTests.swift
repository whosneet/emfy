import CoreGraphics
import CoreText
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import Testing

// F3c tests for the Vision OCR runtime: real recognition of text rendered into a scene image,
// the per-file budget stop (injected clock), the two-tier cache (hit / miss / corrupt-file
// recovery), the disabled path, and sanitisation of recognised text. The real-Vision test
// aside, recognition is injected (`OCRRecognizer`) so the budget and cache are deterministic.

@Suite struct DrawingOCRServiceTests {

    // MARK: Helpers

    /// A throwaway disk cache in a unique temp directory, cleaned up by the OS.
    private func tempDisk() -> OCRDiskCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmfyOCRTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return OCRDiskCache(directory: dir)
    }

    /// A tiny opaque image to stand in for picture pixels where the content is irrelevant.
    private func dummyImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    private func picture(_ hash: String, dest: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100)) -> EmbeddedPicture {
        EmbeddedPicture(contentHash: hash, cgImage: dummyImage(), destRectDevice: dest, transform: .identity)
    }

    /// Renders `string` as large black text on a white background into a CGImage.
    private func textImage(_ string: String, width: Int = 512, height: Int = 160) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: black]
        let attributed = CFAttributedStringCreate(nil, string as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 24, y: 48)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    /// Wraps a counting recognizer that always returns the given lines.
    private func countingRecognizer(_ counter: Counter, lines: @escaping @Sendable () -> [OCRLine]) -> OCRRecognizer {
        OCRRecognizer { _, _ in
            counter.bump()
            return lines()
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    final class SteppingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        private let step: TimeInterval
        init(step: TimeInterval) { self.step = step }
        func clock() -> OCRClock {
            OCRClock {
                self.lock.lock(); defer { self.lock.unlock() }
                let now = self.t
                self.t += self.step
                return now
            }
        }
    }

    // MARK: Real OCR

    @Test func recognisesTextRenderedIntoASceneImage() async throws {
        let image = textImage("EMFY 42")
        let dest = CGRect(x: 20, y: 30, width: 512, height: 160)
        let element = try #require(SceneFactory.makeImage(cgImage: image, destRectDevice: dest, id: 0))
        let scene = Scene(
            pageBoundsDevice: CGRect(x: 0, y: 0, width: 600, height: 400),
            layers: [Layer(id: 0, name: "Layer 1", elements: [element])],
            partition: ScenePartition(structural: [], state: [], drawing: [0], passthrough: [], unitCount: 1),
            source: SceneSource(data: Data(), format: .emf, wasCompressed: false, renderPath: .gdi, unitCount: 1))

        let pictures = DrawingPictureEnumerator.pictures(from: scene)
        #expect(pictures.count == 1)

        let service = DrawingOCRService(disk: tempDisk())
        let runs = await service.recognize(pictures: pictures)
        #expect(!runs.isEmpty)
        let recognised = runs.map(\.text).joined(separator: " ").uppercased()
        #expect(recognised.contains("EMFY"))
        #expect(recognised.contains("42"))
        for run in runs {
            #expect(run.source == .picture)
            // The device box must sit inside the picture's destination rectangle.
            #expect(dest.insetBy(dx: -0.5, dy: -0.5).contains(run.boundsDevice))
        }
    }

    // MARK: Budget

    @Test func stopsAtTheImageBudget() async {
        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "x", x: 0, y: 0, width: 1, height: 1)] }
        var budget = OCRRunBudget()
        budget.maxImages = 3
        let pictures = (0..<6).map { picture("hash-\($0)") }
        let service = DrawingOCRService(disk: tempDisk())
        let runs = await service.recognize(pictures: pictures, budget: budget, recognizer: recognizer)
        #expect(counter.count == 3)
        #expect(runs.count == 3)   // only the recognised pictures produce runs
    }

    @Test func stopsAtTheTimeBudgetKeepingWhatWasFound() async {
        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "x", x: 0, y: 0, width: 1, height: 1)] }
        var budget = OCRRunBudget()
        budget.perFileTimeoutSeconds = 25
        // Each clock read advances 10 s: start=0, then checks at 10, 20, 30 — the third aborts.
        let stepper = SteppingClock(step: 10)
        let clock = stepper.clock()
        let pictures = (0..<6).map { picture("t-\($0)") }
        let service = DrawingOCRService(disk: tempDisk())
        let runs = await service.recognize(pictures: pictures, budget: budget, clock: clock, recognizer: recognizer)
        #expect(counter.count == 2)
        #expect(runs.count == 2)
    }

    // MARK: Cache

    @Test func memoryCacheHitSkipsRecognition() async {
        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "x", x: 0, y: 0, width: 1, height: 1)] }
        let service = DrawingOCRService(disk: tempDisk())
        let pictures = [picture("same"), picture("same")]
        _ = await service.recognize(pictures: pictures, recognizer: recognizer)
        _ = await service.recognize(pictures: pictures, recognizer: recognizer)
        // Recognised once despite four occurrences across two calls (per-call memo + LRU).
        #expect(counter.count == 1)
    }

    @Test func diskCacheHitAcrossServiceInstances() async {
        let disk = tempDisk()
        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "disk", x: 0, y: 0, width: 1, height: 1)] }
        let pictures = [picture("disk-key")]

        let first = DrawingOCRService(disk: disk)
        _ = await first.recognize(pictures: pictures, recognizer: recognizer)
        #expect(counter.count == 1)

        // A fresh service with an empty memory cache but the same disk must not recompute.
        let second = DrawingOCRService(disk: disk)
        let runs = await second.recognize(pictures: pictures, recognizer: recognizer)
        #expect(counter.count == 1)
        #expect(runs.map(\.text) == ["disk"])
    }

    @Test func corruptDiskEntryIsDeletedAndRecomputed() async {
        let disk = tempDisk()
        let key = DrawingOCRService.cacheKey(contentHash: "corrupt", settingsVersion: DrawingOCRService.settingsVersion)
        let fileURL = disk.directory.appendingPathComponent(key).appendingPathExtension("json")
        try? Data("{ not json".utf8).write(to: fileURL)
        #expect(disk.load(key) == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))   // corrupt file deleted

        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "fresh", x: 0, y: 0, width: 1, height: 1)] }
        let service = DrawingOCRService(disk: disk)
        let runs = await service.recognize(pictures: [picture("corrupt")], recognizer: recognizer)
        #expect(counter.count == 1)
        #expect(runs.map(\.text) == ["fresh"])
    }

    // MARK: Disabled path + sanitisation

    @Test func noPicturesMeansNoRecognition() async {
        let counter = Counter()
        let recognizer = countingRecognizer(counter) { [OCRLine(text: "x", x: 0, y: 0, width: 1, height: 1)] }
        let service = DrawingOCRService(disk: tempDisk())
        let runs = await service.recognize(pictures: [], recognizer: recognizer)
        #expect(counter.count == 0)
        #expect(runs.isEmpty)
    }

    @Test func recognisedTextIsSanitised() async {
        let recognizer = OCRRecognizer { _, _ in
            [OCRLine(text: "AB\u{0000}CD\nEF", x: 0, y: 0, width: 1, height: 1)]
        }
        let service = DrawingOCRService(disk: tempDisk())
        let runs = await service.recognize(pictures: [picture("s")], recognizer: recognizer)
        #expect(runs.map(\.text) == ["ABCDEF"])   // NUL and newline stripped
    }
}
