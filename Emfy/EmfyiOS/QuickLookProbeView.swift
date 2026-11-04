#if DEBUG
import QuickLook
import SwiftUI
import UIKit

/// A DEBUG-only Quick Look probe (I4 gate c), compiled out of release builds.
///
/// Launching the app with the environment variable `EMFY_QLPROBE_INDEX` set makes
/// this the window root and opens a `QLPreviewController` over the metafiles in
/// the app's Documents directory, focused on that index. Because the system
/// routes `QLPreviewController` through the registered preview extension, this
/// exercises the embedded "Emfy iOS Quick Look" extension end to end and lets
/// each spot file's preview be screenshotted headlessly from the simulator
/// (`simctl launch` with `SIMCTL_CHILD_EMFY_QLPROBE_INDEX=<n>`), where there is
/// no device and no in-Files automation.
struct QuickLookProbeView: UIViewControllerRepresentable {
    let startIndex: Int

    /// The index requested via the launch environment, or `nil` when the app
    /// should start normally.
    static var requestedStartIndex: Int? {
        guard let raw = ProcessInfo.processInfo.environment["EMFY_QLPROBE_INDEX"],
              let index = Int(raw) else { return nil }
        return index
    }

    /// The metafiles sitting in the app's Documents directory, name-sorted so an
    /// index maps to a stable file across launches.
    static var documentMetafiles: [URL] {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
              let items = try? fileManager.contentsOfDirectory(
                  at: docs, includingPropertiesForKeys: nil
              )
        else { return [] }
        let extensions: Set<String> = ["emf", "wmf", "emz", "wmz"]
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        let count = Self.documentMetafiles.count
        controller.reloadData()
        if count > 0 {
            controller.currentPreviewItemIndex = max(0, min(startIndex, count - 1))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            QuickLookProbeView.documentMetafiles.count
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            QuickLookProbeView.documentMetafiles[index] as NSURL
        }
    }
}

import QuickLookThumbnailing

/// A DEBUG-only thumbnail probe (I4 gate b, simulator fallback): runs
/// `QLThumbnailGenerator` over the Documents metafiles and shows the results in
/// a grid. `QLThumbnailGenerator` dispatches to the registered
/// `QLThumbnailProvider` extension out of process (via
/// `com.apple.quicklook.ThumbnailsAgent`), so a `.thumbnail`-type result proves
/// the embedded "Emfy iOS Thumbnail" extension end to end — the same output the
/// Files app would show. Used because the simulator's Files app cannot enumerate
/// a directly-seeded `UIFileSharingEnabled` Documents folder. Shown when the app
/// is launched with `EMFY_QLPROBE_THUMBS` set.
struct QuickLookThumbnailProbeView: View {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["EMFY_QLPROBE_THUMBS"] != nil
    }

    private struct Result: Identifiable {
        let id = UUID()
        let name: String
        let image: UIImage?
        let typeDescription: String
        let metrics: String
    }

    @State private var results: [Result] = []
    @Environment(\.displayScale) private var displayScale

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(results) { result in
                    VStack(spacing: 6) {
                        Group {
                            if let image = result.image {
                                // scaledToFit + centre so the tile honestly shows
                                // how the page fills the generated image.
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.gray.opacity(0.2)
                            }
                        }
                        .frame(width: 150, height: 150)
                        // Adapts to light/dark so the white-page thumbnail reads
                        // as a card against the tile in both appearances.
                        .background(Color(.secondarySystemBackground))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        Text(result.name).font(.caption).lineLimit(1)
                        Text(result.typeDescription).font(.caption2).foregroundStyle(.secondary)
                        Text(result.metrics).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .task { await generate() }
    }

    private func generate() async {
        let scale = displayScale
        var collected: [Result] = []
        for url in QuickLookProbeView.documentMetafiles {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 150, height: 150),
                scale: scale,
                representationTypes: .thumbnail
            )
            let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let typeText: String
            switch rep?.type {
            case .some(.thumbnail): typeText = "extension thumbnail"
            case .some(.lowQualityThumbnail): typeText = "low-quality thumbnail"
            case .some(.icon): typeText = "generic icon"
            case .some: typeText = "other"
            case .none: typeText = "none"
            }
            var metrics = "no image"
            if let cgImage = rep?.cgImage,
               let box = Self.opaqueBoundingBox(of: cgImage) {
                let w = cgImage.width, h = cgImage.height
                let fillsW = abs(box.width - CGFloat(w)) <= 1 && box.minX <= 1
                let fillsH = abs(box.height - CGFloat(h)) <= 1 && box.minY <= 1
                metrics = "img \(w)×\(h) · bbox \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height)) · fills \(fillsW && fillsH ? "YES" : "NO")"
                NSLog("EMFY_BBOX %@ img=%dx%d bbox=(%d,%d,%d,%d) fills=%@",
                      url.lastPathComponent, w, h,
                      Int(box.minX), Int(box.minY), Int(box.width), Int(box.height),
                      (fillsW && fillsH) ? "YES" : "NO")
            }
            collected.append(
                Result(
                    name: url.lastPathComponent,
                    image: rep?.uiImage,
                    typeDescription: typeText,
                    metrics: metrics
                )
            )
        }
        results = collected
    }

    /// The bounding box, in pixels, of the non-transparent (alpha > 0) region of
    /// `cgImage`. For a correct full-bleed thumbnail (the page fills the image)
    /// this equals the image bounds; the bottom-left-corner scale bug would make
    /// it `1/scale` of the image.
    private static func opaqueBoundingBox(of cgImage: CGImage) -> CGRect? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width where pixels[rowStart + x * 4 + 3] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return CGRect(x: 0, y: 0, width: 0, height: 0) }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
#endif
