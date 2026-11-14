import CoreGraphics
import EMFEdit
import EMFParse
import EMFRender
import Foundation
import ImageIO
import Vision

// MARK: - OCR of embedded pictures: the Vision runtime (F3c)
//
// Finds the embedded pictures in a loaded drawing, recognises their text with Vision OFF the
// main actor within the per-file budget (`OCRBudget`), and lifts each line into a
// `DrawingTextRun` with `source == .picture` so it joins Find, Copy All Text and Spotlight.
//
// The pure geometry/budget/cache-key helpers live in `DrawingOCR.swift`; the recognition and
// the two-tier cache live here. The Vision request is abstracted behind `OCRRecognizer` and
// the clock behind `OCRClock` so the budget, cache and sanitisation are testable without the
// (slow, model-backed) Vision runtime. §8: every internal size is bounded — at most
// `maxImages` recognitions, each picture downsampled to the pixel cap, and the whole pass
// abandoned after the time cap, keeping whatever was recognised so far.

/// One embedded picture ready for recognition: its decoded pixels, the device-space rectangle
/// it is drawn into, and the element transform in effect. `@unchecked Sendable` for the same
/// reason `ResolvedDrawOp` is — its only reference member is an immutable `CGImage`, safe to
/// read from the recognition thread.
struct EmbeddedPicture: @unchecked Sendable {
    /// SHA-256 of the picture's raw bytes (its content-addressed cache identity).
    let contentHash: String
    let cgImage: CGImage
    /// The device-space destination the picture fills.
    let destRectDevice: CGRect
    /// The element transform in effect (identity for an axis-aligned placement — the
    /// destination rectangle already folds the world→device mapping in).
    let transform: CGAffineTransform
}

// MARK: - Picture enumeration

/// Lifts the embedded pictures out of the ONE interpreter: the renderer's
/// `PlaybackObservation` (viewer mode) or the edited `Scene` (edit mode). Pure and
/// nonisolated, so it runs inside the same off-main task that extracts text.
enum DrawingPictureEnumerator {

    /// Embedded pictures from a playback observation. GDI images live in `ops`; EMF+ images
    /// live in `plusEntries` (`.plus`). A GDI image inside a GetDC window appears in both,
    /// so — like the text extractor — only `.plus` entries are read from `plusEntries`.
    static func pictures(from observation: PlaybackObservation) -> [EmbeddedPicture] {
        var pictures: [EmbeddedPicture] = []
        for op in observation.ops where op.kind == .image {
            guard let lifted = op.image, let dib = lifted.sourceDIB,
                  let bytes = rawBytes(ofDIB: dib),
                  let cgImage = BitmapDecoder.cgImage(from: dib) else { continue }
            let dest = deviceRect(forGDI: lifted, op: op)
            guard dest.width >= 1, dest.height >= 1 else { continue }
            pictures.append(EmbeddedPicture(
                contentHash: OCRCacheKey.make(forImageData: bytes),
                cgImage: cgImage, destRectDevice: dest, transform: .identity))
        }
        for entry in observation.plusEntries {
            guard case .plus(let op) = entry, op.kind == .image, let plus = op.image,
                  let cgImage = EMFPlusImageDecoder.cgImage(from: plus.image) else { continue }
            let dest = plus.destRectDevice.standardized
            guard dest.width >= 1, dest.height >= 1 else { continue }
            pictures.append(EmbeddedPicture(
                contentHash: OCRCacheKey.make(forImageData: rawBytes(ofPlus: plus.image)),
                cgImage: cgImage, destRectDevice: dest, transform: .identity))
        }
        return pictures
    }

    /// Embedded pictures from an edited scene: every visible image element, decoded through
    /// EMFRender's own decoders (EMF+ image object, or GDI DIB).
    static func pictures(from scene: Scene) -> [EmbeddedPicture] {
        var pictures: [EmbeddedPicture] = []
        for element in scene.elements where element.kind == .image && !element.hidden {
            guard let image = element.image else { continue }
            let decoded: CGImage?
            let bytes: Data?
            if let plus = image.emfPlusImage {
                decoded = EMFPlusImageDecoder.cgImage(from: plus)
                bytes = rawBytes(ofPlus: plus)
            } else if let dib = image.sourceDIB {
                decoded = BitmapDecoder.cgImage(from: dib)
                bytes = rawBytes(ofDIB: dib)
            } else {
                decoded = nil
                bytes = nil
            }
            guard let cgImage = decoded, let data = bytes else { continue }
            let dest = image.destRectDevice.standardized
            guard dest.width >= 1, dest.height >= 1 else { continue }
            pictures.append(EmbeddedPicture(
                contentHash: OCRCacheKey.make(forImageData: data),
                cgImage: cgImage, destRectDevice: dest, transform: .identity))
        }
        return pictures
    }

    /// The device-space destination of a GDI image op: the resolved device geometry when it
    /// carries one, else the logical destination mapped through the op's transform.
    private static func deviceRect(forGDI lifted: LiftedImage, op: ResolvedDrawOp) -> CGRect {
        let box = op.deviceGeometry.boundingBox
        if !box.isNull, !box.isEmpty { return box.standardized }
        let logical = CGRect(
            x: CGFloat(lifted.destOrigin.x), y: CGFloat(lifted.destOrigin.y),
            width: CGFloat(lifted.destSize.cx), height: CGFloat(lifted.destSize.cy)).standardized
        return logical.applying(op.deviceTransform).standardized
    }

    private static func rawBytes(ofPlus image: EMFPlusImage) -> Data {
        switch image.content {
        case .bitmap(_, let data): return data
        case .metafile(_, let data): return data
        }
    }

    /// The hashable bytes of a GDI DIB: the dimensions and bit depth prefixed to the pixel
    /// bytes, so two different-sized bitmaps with coincidentally equal pixel runs don't
    /// collide. Nil when the DIB carries no decoded pixels.
    private static func rawBytes(ofDIB dib: DIB) -> Data? {
        guard case .pixels(let bytes, _, _) = dib.content else { return nil }
        var header = Data()
        var width = dib.width.littleEndian
        var height = dib.height.littleEndian
        var bitCount = dib.bitCount.littleEndian
        withUnsafeBytes(of: &width) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &height) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &bitCount) { header.append(contentsOf: $0) }
        return header + bytes
    }
}

// MARK: - Budget, clock and recognizer seams

/// The per-run OCR budget, defaulting to `OCRBudget`. A parameter so tests can shrink the
/// image count without touching the shipped limits.
struct OCRRunBudget: Sendable {
    var maxImages = OCRBudget.maxImages
    var maxLongSidePixels = OCRBudget.maxLongSidePixels
    var perFileTimeoutSeconds = OCRBudget.perFileTimeoutSeconds
}

/// A monotonic clock, injectable so the time budget can be driven deterministically in tests.
struct OCRClock: Sendable {
    var now: @Sendable () -> TimeInterval
    static let monotonic = OCRClock { ProcessInfo.processInfo.systemUptime }
}

/// The recognition step, abstracted so tests inject a fake and the budget/cache/sanitisation
/// can be exercised without the Vision runtime. Production uses `.vision`.
struct OCRRecognizer: Sendable {
    /// Recognises the text in one image, downsampling to the long-side cap first; returns the
    /// lines in Vision's normalised bottom-left space.
    var recognize: @Sendable (CGImage, CGFloat) -> [OCRLine]

    static let vision = OCRRecognizer { image, maxLongSide in
        VisionTextRecognizer.recognize(image, maxLongSidePixels: maxLongSide)
    }
}

// MARK: - The service

/// The app's OCR service: content-keyed, budgeted, two-tier-cached recognition of a drawing's
/// embedded pictures. An actor so the caches are accessed serially and the Vision work runs
/// off the main actor; one shared instance per process.
actor DrawingOCRService {
    static let shared = DrawingOCRService()

    /// Bumped whenever the recognition parameters change, so an old cache entry is ignored
    /// rather than trusted. Part of every cache key.
    static let settingsVersion = 1

    private let memory: OCRMemoryCache
    private let disk: OCRDiskCache?

    init(memoryLimit: Int = 32, disk: OCRDiskCache? = OCRDiskCache.shared) {
        self.memory = OCRMemoryCache(limit: memoryLimit)
        self.disk = disk
    }

    /// Empties the in-memory cache (the Settings toggle turning OCR off).
    func clearMemoryCache() { memory.clear() }

    /// Empties both cache tiers (ST4): used on Clear Recents and when leaving Private
    /// mode, so recognised text leaves no in-memory or on-disk trace.
    func purgeAllCaches() {
        memory.clear()
        disk?.purgeAll()
    }

    /// The combined cache key: content hash plus the OCR settings version.
    static func cacheKey(contentHash: String, settingsVersion: Int) -> String {
        "\(contentHash)-v\(settingsVersion)"
    }

    /// Recognises the text in `pictures` within `budget`, returning picture text runs in
    /// device space. Cache hits (memory, then disk) skip recognition; past the image or time
    /// cap, no further pictures are recognised and whatever was found so far is returned.
    func recognize(
        pictures: [EmbeddedPicture],
        settingsVersion: Int = DrawingOCRService.settingsVersion,
        budget: OCRRunBudget = OCRRunBudget(),
        clock: OCRClock = .monotonic,
        recognizer: OCRRecognizer = .vision
    ) -> [DrawingTextRun] {
        let start = clock.now()
        var runs: [DrawingTextRun] = []
        /// Lines recognised (or loaded) during this call, so a picture repeated within one
        /// file is recognised at most once even before it reaches the shared caches.
        var recognizedThisCall: [String: [OCRLine]] = [:]
        var recognizedCount = 0

        for picture in pictures {
            let key = Self.cacheKey(contentHash: picture.contentHash, settingsVersion: settingsVersion)
            let lines: [OCRLine]
            if let memo = recognizedThisCall[key] {
                lines = memo
            } else if let hit = memory.get(key) {
                lines = hit
                recognizedThisCall[key] = hit
            } else if let hit = disk?.load(key) {
                lines = hit
                memory.set(key, hit)
                recognizedThisCall[key] = hit
            } else {
                guard recognizedCount < budget.maxImages else { continue }
                guard clock.now() - start < budget.perFileTimeoutSeconds else { break }
                recognizedCount += 1
                let recognized = recognizer.recognize(picture.cgImage, budget.maxLongSidePixels)
                memory.set(key, recognized)
                disk?.store(key, recognized)
                recognizedThisCall[key] = recognized
                lines = recognized
            }
            for line in lines {
                let clean = DrawingTextExtractor.sanitize(line.text)
                guard !clean.isEmpty else { continue }
                let box = OCRGeometry.deviceBox(
                    fromNormalized: line.normalizedBox,
                    destRectDevice: picture.destRectDevice,
                    transform: picture.transform)
                runs.append(DrawingTextRun(
                    text: clean, boundsDevice: box, fontFamily: nil, fontSize: nil, source: .picture))
            }
        }
        return runs
    }
}

// MARK: - Vision runtime

/// The concrete Vision text recogniser: `.accurate`, automatic language detection, language
/// correction on. Kept separate from the service so the service is testable without Vision.
enum VisionTextRecognizer {
    static func recognize(_ image: CGImage, maxLongSidePixels: CGFloat) -> [OCRLine] {
        let target = OCRImageDownsampler.downsample(image, maxLongSidePixels: maxLongSidePixels)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: target, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        var lines: [OCRLine] = []
        lines.reserveCapacity(results.count)
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(OCRLine(text: candidate.string, box: observation.boundingBox))
        }
        return lines
    }
}

/// Downsamples a picture so its long side is at most the pixel cap, using ImageIO's
/// thumbnail path. Images already within budget are returned unchanged.
enum OCRImageDownsampler {
    static func downsample(_ image: CGImage, maxLongSidePixels: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxLongSidePixels, maxLongSidePixels > 0 else { return image }
        guard let data = pngData(image),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return image }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSidePixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}
