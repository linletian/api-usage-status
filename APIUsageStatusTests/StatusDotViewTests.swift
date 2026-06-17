import XCTest
import SwiftUI
@testable import APIUsageStatus

/// Tests for `StatusDotView`.
///
/// `StatusDotView` renders a 10×10 pt circle whose fill color reflects the
/// `isTracking` flag. The view body is a `Circle().fill(...).frame(...)` chain,
/// so a rendered SwiftUI `Image` of the view exposes the resolved `Color`
/// via `Image.uiColor` / `NSImage` introspection helpers.
///
/// We snapshot the view to PNG and decode the dominant pixel to assert the
/// fill color, which is more robust than walking the SwiftUI modifier graph
/// (which is internal-only and brittle across SDK versions).
@MainActor
final class StatusDotViewTests: XCTestCase {

    // MARK: - Helpers

    /// Renders `view` into an `NSImage` of the given pixel size.
    /// Uses a `NSHostingView` snapshot so the resolved SwiftUI colors
    /// (including dark-mode `Color` resolution) are baked into the bitmap.
    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 20, height: 20)) -> NSImage {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        return hosting.snapshot()
    }

    /// Reads the RGBA value of the center pixel of the supplied image.
    /// Returns `nil` if the image cannot be converted to a CGImage.
    private func centerPixelColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        let centerX = width / 2
        let centerY = height / 2

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: info
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: -centerX, y: -centerY, width: width, height: height))
        return NSColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: CGFloat(pixel[3]) / 255.0
        )
    }

    // MARK: - Color resolution

    /// `isTracking == true` must resolve to the `Color.trackingOn` value.
    /// We assert that the rendered center pixel equals the resolved RGBA of
    /// `Color.trackingOn` under the current appearance, ensuring the view
    /// is actually wired to the theme color rather than a hard-coded green.
    func testIsTrackingTrueFillsWithTrackingOn() {
        let view = StatusDotView(isTracking: true)
        let image = render(view)
        guard let rendered = centerPixelColor(of: image) else {
            XCTFail("Failed to read center pixel of rendered StatusDotView")
            return
        }
        let expected = NSColor(Color.trackingOn).usingColorSpace(.deviceRGB) ?? NSColor(Color.trackingOn)

        XCTAssertEqual(
            rendered.redComponent, expected.redComponent, accuracy: 0.05,
            "Red channel must match Color.trackingOn"
        )
        XCTAssertEqual(
            rendered.greenComponent, expected.greenComponent, accuracy: 0.05,
            "Green channel must match Color.trackingOn (the dominant channel for the green token)"
        )
        XCTAssertGreaterThan(
            rendered.greenComponent, rendered.redComponent,
            "trackingOn is a green token; green channel must dominate red"
        )
    }

    /// `isTracking == false` must resolve to the `Color.trackingOff` value.
    /// The gray token has near-equal R/G/B, which is the key invariant we
    /// check — green-on/off must NOT skew green like `trackingOn` does.
    func testIsTrackingFalseFillsWithTrackingOff() {
        let view = StatusDotView(isTracking: false)
        let image = render(view)
        guard let rendered = centerPixelColor(of: image) else {
            XCTFail("Failed to read center pixel of rendered StatusDotView")
            return
        }
        let expected = NSColor(Color.trackingOff).usingColorSpace(.deviceRGB) ?? NSColor(Color.trackingOff)

        XCTAssertEqual(
            rendered.redComponent, expected.redComponent, accuracy: 0.05,
            "Red channel must match Color.trackingOff"
        )
        XCTAssertEqual(
            rendered.greenComponent, expected.greenComponent, accuracy: 0.05,
            "Green channel must match Color.trackingOff"
        )
        XCTAssertEqual(
            rendered.redComponent, rendered.greenComponent, accuracy: 0.05,
            "trackingOff is a gray token; R and G channels must be equal"
        )
    }
}

// MARK: - NSHostingView snapshot helper

private extension NSHostingView {
    /// Renders the hosting view into an `NSImage` of its current bounds.
    /// Uses `bitmapImageRepForCachingDisplay` so the result captures the
    /// resolved SwiftUI state, including appearance-aware colors.
    func snapshot() -> NSImage {
        let bounds = self.bounds
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
