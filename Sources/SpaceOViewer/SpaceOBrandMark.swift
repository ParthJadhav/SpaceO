import AppKit
import SwiftUI

/// The canonical product mark bundled by `make-viewer-app.sh` and derived from the same source
/// as the app icon and README artwork.
struct SpaceOBrandMark: View {
    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }

    /// An 18-point template rendering for the menu bar extra, so it follows the bar's tint.
    static let menuBarImage: NSImage = {
        let source = image
        let target = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        target.isTemplate = true
        target.accessibilityDescription = "SpaceO"
        return target
    }()

    /// The app icon first: it has the macOS icon shape with transparent corners, where the logo
    /// PNG is an opaque square that reads as a pale tile on a dark window.
    private static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "SpaceO", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        if let url = Bundle.main.url(forResource: "spaceo-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSApplication.shared.applicationIconImage
    }()
}
