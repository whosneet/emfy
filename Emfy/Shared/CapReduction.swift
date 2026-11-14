import SwiftUI

// The cap-reduction confirmation alert and its "Save Copies…" folder exporter used to live
// here, hosting `CapReductionController`'s pending/export flow. Under ST3 (f18399e) the cap
// never evicts an owned copy, so that confirmation could never fire; the flow and this
// `.capReduction` view modifier have been removed. Lowering "Recents to keep" now applies at
// once via `CapReductionController.handleChange` → `RecentsStore.applyCap`.
//
// This file is intentionally left in the build (no new/removed source references) and carries
// no view code.
