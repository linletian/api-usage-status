import XCTest
import SwiftUI
@testable import APIUsageStatus

/// Snapshot-style tests for `FlowingGlowBar` (rendered through `ShimmerBar`
/// with a fixed phase, so the rendered frame is deterministic).
///
/// Golden Master workflow:
///   1. First run generates reference PNGs in `ReferenceImages/FlowingGlowBar/`
///   2. Subsequent runs compare rendered PNG bytes against the reference.
/// If the rendering logic changes intentionally, delete the reference folder
/// and re-run.
@MainActor
final class FlowingGlowBarTests: XCTestCase {

    private let barWidth: CGFloat = 200
    private let barHeight: CGFloat = 3
    private let shimmerWidthFraction: CGFloat = 0.45

    // MARK: - Snapshot helpers

    private var referenceImagesDir: URL {
        let sourceFile = URL(fileURLWithPath: #file)
        let refDir = sourceFile
            .deletingLastPathComponent()
            .appendingPathComponent("ReferenceImages")
            .appendingPathComponent("FlowingGlowBar")
        try? FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        return refDir
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private func render(phase: CGFloat) -> NSImage? {
        let view = ShimmerBar(phase: phase, barHeight: barHeight, shimmerWidthFraction: shimmerWidthFraction)
            .frame(width: barWidth, height: barHeight)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.nsImage
    }

    private func assertSnapshot(phase: CGFloat, file: StaticString = #file, line: UInt = #line) {
        let name = String(format: "phase_%03d", Int((phase * 100).rounded()))
        guard let image = render(phase: phase) else {
            XCTFail("Failed to render view for phase=\(phase)", file: file, line: line)
            return
        }
        guard let data = pngData(from: image) else {
            XCTFail("Failed to encode image as PNG for phase=\(phase)", file: file, line: line)
            return
        }
        let referenceURL = referenceImagesDir.appendingPathComponent("\(name).png")
        if !FileManager.default.fileExists(atPath: referenceURL.path) {
            try? data.write(to: referenceURL)
            XCTFail("Reference image created at \(referenceURL.path). Re-run test to verify.", file: file, line: line)
            return
        }
        guard let reference = try? Data(contentsOf: referenceURL) else {
            XCTFail("Failed to read reference for phase=\(phase)", file: file, line: line)
            return
        }
        XCTAssertEqual(
            data,
            reference,
            "Snapshot mismatch for phase=\(phase). If the change is intentional, delete ReferenceImages/FlowingGlowBar/ and re-run.",
            file: file,
            line: line
        )
    }

    // MARK: - Smoke test

    func testRendersNonEmptyImage() {
        guard let image = render(phase: 0.0) else {
            XCTFail("ImageRenderer returned nil")
            return
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        guard let tiff = image.tiffRepresentation else {
            XCTFail("Missing TIFF representation")
            return
        }
        XCTAssertGreaterThan(tiff.count, 100, "Rendered image should carry non-trivial pixel data")
    }

    // MARK: - Snapshot tests across the animation cycle

    func testPhaseZero()        { assertSnapshot(phase: 0.0) }
    func testPhaseQuarter()     { assertSnapshot(phase: 0.25) }
    func testPhaseHalf()        { assertSnapshot(phase: 0.5) }
    func testPhaseThreeQuart()  { assertSnapshot(phase: 0.75) }
}
