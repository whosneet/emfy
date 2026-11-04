import SwiftUI
import UIKit

/// What drives the share sheet: a rendered (or original) file on disk, shared as
/// a URL so the activity sheet shows the right filename and extension-derived
/// type. `Identifiable` for `.sheet(item:)`.
struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL

    var items: [Any] { [url] }
}

/// A thin `UIActivityViewController` bridge for the Share menu.
///
/// We use this rather than `ShareLink` because the approved design is a Menu of
/// plain buttons where each entry renders *before* the sheet appears: the render
/// runs off-main, cancellably, with our own spinner past ~0.3 s, and only then is
/// the sheet presented with the finished file. `ShareLink` owns the tap and
/// presents immediately, so it can't host that progress/cancel step (Axiom
/// `transferable-ref`, Part 5: reach for `UIActivityViewController` for
/// "programmatic presentation control" and lazy provision). Presented through a
/// SwiftUI `.sheet`, the controller gets its container for free, so no iPad
/// popover-anchor crash.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
