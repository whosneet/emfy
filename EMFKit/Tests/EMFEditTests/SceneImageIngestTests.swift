import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EMFEdit

/// E3c: the untrusted-image ingest (§8/privacy). The §8 caps reject oversize input and
/// over-resolution sources, downsample over-long images, and the re-encode path strips
/// camera/location metadata (GPS) from what the scene stores.
struct SceneImageIngestTests {

    // MARK: - Caps

    @Test func imageDecisionRejectsOverCaps() {
        // Over the 40 MB input cap.
        #expect(SceneImageImport.decision(inputBytes: SceneImageImport.maxInputBytes + 1, pixelWidth: 100, pixelHeight: 100) == .reject(.tooLarge))
        // Over the 64 MP pixel cap (9000 × 8000 = 72 MP).
        #expect(SceneImageImport.decision(inputBytes: 1000, pixelWidth: 9000, pixelHeight: 8000) == .reject(.tooManyPixels))
        // A non-positive size is undecodable.
        #expect(SceneImageImport.decision(inputBytes: 1000, pixelWidth: 0, pixelHeight: 10) == .reject(.undecodable))
        // Over 4096 on the long side → downsample.
        #expect(SceneImageImport.decision(inputBytes: 1000, pixelWidth: 5000, pixelHeight: 100) == .downsample)
        // Within every cap → full.
        #expect(SceneImageImport.decision(inputBytes: 1000, pixelWidth: 800, pixelHeight: 600) == .full)
        // Exactly at the pixel cap is accepted (8000 × 8000 = 64 MP, long side ≤ 4096? no → downsample).
        #expect(SceneImageImport.decision(inputBytes: 1000, pixelWidth: 8000, pixelHeight: 8000) == .downsample)
    }

    @Test func oversizeInputIsRejected() {
        let data = Data(count: SceneImageImport.maxInputBytes + 1)
        #expect(SceneImageImport.decode(data) == .failure(.tooLarge))
    }

    @Test func garbageIsUndecodable() {
        #expect(SceneImageImport.decode(Data([0x00, 0x01, 0x02, 0x03])) == .failure(.undecodable))
    }

    @Test func overLongSideImageIsDownsampled() throws {
        // A 5000 × 100 source → the long side clamps to 4096.
        let png = try pngFixture(width: 5000, height: 100)
        let cg = try #require(try SceneImageImport.decode(png).get())
        #expect(max(cg.width, cg.height) <= SceneImageImport.maxLongSide)
        #expect(cg.width < 5000)
    }

    @Test func withinCapImageDecodesAtFullSize() throws {
        let png = try pngFixture(width: 320, height: 200)
        let cg = try #require(try SceneImageImport.decode(png).get())
        #expect(cg.width == 320)
        #expect(cg.height == 200)
    }

    // MARK: - Metadata stripping (GPS)

    @Test func insertedImageHasNoGPSMetadata() throws {
        // A JPEG fixture carrying a GPS dictionary; the source really does carry GPS.
        let jpeg = try jpegWithGPS(width: 64, height: 48)
        #expect(gpsPresent(in: jpeg))

        let cg = try #require(try SceneImageImport.decode(jpeg).get())
        let element = try #require(SceneFactory.makeImage(cgImage: cg, destRectDevice: CGRect(x: 0, y: 0, width: 64, height: 48), id: 0))
        let plus = try #require(element.image?.emfPlusImage)
        guard case .bitmap(let header, let storedPNG) = plus.content else {
            Issue.record("stored image is not a bitmap"); return
        }
        #expect(header.bitmapDataType == 1)   // compressed PNG
        // The stored bytes carry NO GPS metadata.
        #expect(!gpsPresent(in: storedPNG))
    }

    // MARK: - Fixtures

    private func gradientImage(width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.3, blue: 0.1, alpha: 1)] as CFArray
        let gradient = try #require(CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]))
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return try #require(ctx.makeImage())
    }

    private func pngFixture(width: Int, height: Int) throws -> Data {
        let cg = try gradientImage(width: width, height: height)
        let buffer = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return buffer as Data
    }

    private func jpegWithGPS(width: Int, height: Int) throws -> Data {
        let cg = try gradientImage(width: width, height: height)
        let buffer = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 51.5007,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1246,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]
        let props: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return buffer as Data
    }

    private func gpsPresent(in data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return props[kCGImagePropertyGPSDictionary] != nil
    }
}
