import Foundation

/// Placeholder for the EMF playback engine.
///
/// Record playback into a `CGContext` (pen/brush/font state, the coordinate
/// pipeline, path brackets, text, and bitmaps) lands in phase 2. This target
/// exists now only so the package graph and import rules
/// (Foundation + CoreGraphics + CoreText, no AppKit/SwiftUI) are established
/// from phase 1. It carries no logic yet.
public enum EMFRender {}
