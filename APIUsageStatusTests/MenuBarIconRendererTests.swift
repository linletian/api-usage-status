import XCTest
@testable import APIUsageStatus

// MARK: - MenuBarIconRendererTests

/// Property-assertion tests for MenuBarIconRenderer.
/// Covers breathing state tracking, shadow application, animation lifecycle,
/// monochrome mode, and multi-slot synchronization.
@MainActor
final class MenuBarIconRendererTests: XCTestCase {

    private var renderer: MenuBarIconRenderer!

    override func setUp() {
        super.setUp()
        renderer = MenuBarIconRenderer()
    }

    override func tearDown() {
        renderer.stopBreathingAnimation()
        renderer = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSlot(
        uuid: String = UUID().uuidString,
        colorState: ColorState = .normal,
        instanceType: InstanceType = .quota(percent: 75, usageValue: "75", limitValue: "100", cycleRemainingSeconds: nil),
        shortName: String = "TST",
        sortOrder: Int = 0
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: "Test",
            shortName: shortName,
            instanceType: instanceType,
            sortOrder: sortOrder,
            colorState: colorState,
            provider: "test",
            dimension: "test"
        )
    }

    // MARK: - Snapshot Helpers

    private var referenceImagesDir: URL {
        let sourceFile = URL(fileURLWithPath: #file)
        let refDir = sourceFile.deletingLastPathComponent().appendingPathComponent("ReferenceImages")
        try? FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        return refDir
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    private func assertSnapshot(_ image: NSImage, named name: String, file: StaticString = #file, line: UInt = #line) {
        let referenceURL = referenceImagesDir.appendingPathComponent("\(name).png")

        guard let pngData = pngData(from: image) else {
            XCTFail("Failed to encode image as PNG", file: file, line: line)
            return
        }

        if !FileManager.default.fileExists(atPath: referenceURL.path) {
            try? pngData.write(to: referenceURL)
            XCTFail("Reference image created at \(referenceURL.path). Re-run test to verify.", file: file, line: line)
            return
        }

        guard let referenceData = try? Data(contentsOf: referenceURL) else {
            XCTFail("Failed to read reference image", file: file, line: line)
            return
        }

        XCTAssertEqual(
            pngData,
            referenceData,
            "Snapshot mismatch for \(name). If the change is intentional, delete ReferenceImages/ and re-run.",
            file: file,
            line: line
        )
    }

    // MARK: - Breathing State Tracking

    func testBreathingSlotsTrackingWarning() {
        let uuid = "warning-uuid"
        let slot = makeSlot(uuid: uuid, colorState: .warning)

        renderer.updateBreathingState(slotViewDataList: [slot])

        XCTAssertTrue(renderer.needsBreathingAnimation(),
                       "Warning slot should trigger breathing animation")
        // Verify render with breathing active produces valid output
        renderer.startBreathingAnimation()
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testBreathingSlotsTrackingCritical() {
        let uuid = "critical-uuid"
        let slot = makeSlot(uuid: uuid, colorState: .critical)

        renderer.updateBreathingState(slotViewDataList: [slot])

        XCTAssertTrue(renderer.needsBreathingAnimation(),
                       "Critical slot should trigger breathing animation")
        renderer.startBreathingAnimation()
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testNoBreathingWhenAllNormal() {
        let slot = makeSlot(colorState: .normal)

        renderer.updateBreathingState(slotViewDataList: [slot])

        XCTAssertFalse(renderer.needsBreathingAnimation(),
                        "Normal slot should not trigger breathing animation")
    }

    func testBreathingWhenMixed() {
        let normal = makeSlot(uuid: "normal-1", colorState: .normal)
        let warning = makeSlot(uuid: "warn-1", colorState: .warning)
        let critical = makeSlot(uuid: "crit-1", colorState: .critical)

        renderer.updateBreathingState(slotViewDataList: [normal, warning, critical])

        XCTAssertTrue(renderer.needsBreathingAnimation(),
                       "Mixed states containing warning/critical should trigger breathing")
        XCTAssertFalse(renderer.isBreathingAnimationRunning(),
                        "Breathing should not be running before explicit start")
    }

    // MARK: - Render Output Size

    func testRenderOutputSizeWithShadow() {
        let slot = makeSlot(uuid: "shadow-slot", colorState: .warning)

        renderer.updateBreathingState(slotViewDataList: [slot])
        renderer.startBreathingAnimation()

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                        "Output image should be 22pt high with shadow applied")
        XCTAssertGreaterThan(image.size.width, 0,
                              "Output image should have non-zero width with shadow applied")
    }

    func testRenderOutputSizeWithoutShadow() {
        let slot = makeSlot(colorState: .normal)

        renderer.updateBreathingState(slotViewDataList: [slot])

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                        "Output image should be 22pt high without shadow")
        XCTAssertGreaterThan(image.size.width, 0,
                              "Output image should have non-zero width without shadow")
    }

    // MARK: - Animation Lifecycle

    func testAnimationLifecycleStartStop() {
        let slot = makeSlot(colorState: .warning)
        renderer.updateBreathingState(slotViewDataList: [slot])

        renderer.startBreathingAnimation()
        XCTAssertTrue(renderer.isBreathingAnimationRunning(),
                       "isBreathingAnimationRunning should be true after start")

        renderer.stopBreathingAnimation()
        XCTAssertFalse(renderer.isBreathingAnimationRunning(),
                        "isBreathingAnimationRunning should be false after stop")
    }

    func testAnimationStartWhenAlreadyRunningIsIdempotent() {
        let slot = makeSlot(colorState: .warning)
        renderer.updateBreathingState(slotViewDataList: [slot])

        renderer.startBreathingAnimation()
        XCTAssertTrue(renderer.isBreathingAnimationRunning())

        // Second start should not crash or change state
        renderer.startBreathingAnimation()
        XCTAssertTrue(renderer.isBreathingAnimationRunning(),
                       "Second start should be idempotent and keep running")
    }

    // MARK: - State Update Clearing

    func testBreathingStateUpdateClearsRemovedUUIDs() {
        let warningSlot = makeSlot(uuid: "warn-removed", colorState: .warning)
        let normalSlot = makeSlot(uuid: "normal-new", colorState: .normal)

        // First: update with warning — breathing should be needed
        renderer.updateBreathingState(slotViewDataList: [warningSlot])
        XCTAssertTrue(renderer.needsBreathingAnimation(),
                       "Should need breathing after warning update")

        // Then: update with all normal — breathing should be cleared
        renderer.updateBreathingState(slotViewDataList: [normalSlot])
        XCTAssertFalse(renderer.needsBreathingAnimation(),
                        "Should not need breathing after switching to all normal")
    }

    // MARK: - Render With Shadow Breathing

    func testRenderWithBreathingSlotsAppliedShadowParams() {
        let slot = makeSlot(uuid: "shadow-verify", colorState: .critical)

        renderer.updateBreathingState(slotViewDataList: [slot])
        renderer.startBreathingAnimation()

        // Brief wait so elapsed time > 0, ensuring breathing phase has advanced
        Thread.sleep(forTimeInterval: 0.05)

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                        "Image with breathing shadow should have correct height")
        XCTAssertGreaterThan(image.size.width, 0,
                              "Image with breathing shadow should have non-zero width")
        // Verify image produced real content (not a blank canvas)
        XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                         "Should produce valid CGImage when breathing shadow is applied")
    }

    // MARK: - Monochrome Mode

    func testMonochromeModeRender() {
        let slot = makeSlot(colorState: .normal)

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: true
        )

        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                        "Monochrome output should be 22pt high")
        XCTAssertGreaterThan(image.size.width, 0,
                              "Monochrome output should have non-zero width")
    }

    // MARK: - Multiple Slots Synchronization

    func testMultipleSlotsSameStateSynchronized() {
        let slot1 = makeSlot(uuid: "sync-slot-1", colorState: .warning, shortName: "S1")
        let slot2 = makeSlot(uuid: "sync-slot-2", colorState: .warning, shortName: "S2")

        renderer.updateBreathingState(slotViewDataList: [slot1, slot2])
        renderer.startBreathingAnimation()

        let image1 = renderer.render(
            slotViewDataList: [slot1, slot2],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 2,
            enabledCount: 2,
            isDarkBackground: false
        )

        // Short delay to progress the shared breathingStartTime
        Thread.sleep(forTimeInterval: 0.1)

        let image2 = renderer.render(
            slotViewDataList: [slot1, slot2],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 2,
            enabledCount: 2,
            isDarkBackground: false
        )

        XCTAssertEqual(image1.size.height, 22, accuracy: 0.1)
        XCTAssertGreaterThan(image1.size.width, 0)
        XCTAssertEqual(image2.size.height, 22, accuracy: 0.1)
        XCTAssertGreaterThan(image2.size.width, 0)
        // Both renders should produce consistent dimensions — two slots always
        // use the same shared breathingStartTime, so the phase advances identically
        XCTAssertEqual(image1.size.width, image2.size.width, accuracy: 0.1,
                        "Render dimensions should be consistent across animation frames")
        // With two slots, the width should be wider than a single slot
        // (two content-sized slots + 10pt gap)
        XCTAssertGreaterThan(image1.size.width, 30,
                              "Two slots should produce wider output than one slot")
    }

    // MARK: - Snapshot Tests

    func testSnapshotNormalNoBreathingColor() {
        let slot = makeSlot(uuid: "snap-normal", colorState: .normal)
        renderer.updateBreathingState(slotViewDataList: [slot])

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "normal_no_breathing_color")
    }

    func testSnapshotWarningBreathingInhale() {
        let uuid = "snap-warning"
        let slot = makeSlot(uuid: uuid, colorState: .warning)

        renderer.updateBreathingState(slotViewDataList: [slot])
        // Inject deterministic time: 0.7s into 4.0s warning cycle
        // At t=0.7s within inhale (1.4s), normalized t = 0.5, phase = 0.25
        renderer.currentTimeProvider = { 0.7 }
        renderer.startBreathingAnimation()

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "warning_breathing_inhale")
    }

    func testSnapshotCriticalBreathingInhale() {
        let uuid = "snap-critical"
        let slot = makeSlot(uuid: uuid, colorState: .critical)

        renderer.updateBreathingState(slotViewDataList: [slot])
        // Inject deterministic time: 0.35s into 2.0s critical cycle
        // At t=0.35s within inhale (0.7s), normalized t = 0.5, phase = 0.25
        renderer.currentTimeProvider = { 0.35 }
        renderer.startBreathingAnimation()

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "critical_breathing_inhale")
    }

    // MARK: - Unlimited metric snapshots

    private func makeUnlimitedSlot(
        uuid: String = UUID().uuidString,
        colorState: ColorState = .normal,
        shortName: String = "TU",
        sortOrder: Int = 0
    ) -> SlotViewData {
        let snapshot = MetricSnapshot(
            key: "weekly",
            group: "general",
            window: "weekly",
            percent: 0.0,
            displayUsage: "0.0",
            displayLimit: "",
            cycleRemainingSeconds: nil,
            colorState: colorState,
            configIndex: 1,
            displayInMenuBar: true,
            isUnlimited: true,
            shortName: nil
        )
        return SlotViewData(
            uuid: uuid,
            displayName: "Test Unlimited",
            shortName: shortName,
            sortOrder: sortOrder,
            provider: "minimax",
            metricSnapshots: [snapshot]
        )
    }

    /// Unlimited metric snapshots must render ∞ (single char) instead of the
    /// percent-based text (e.g. "0%"). Since ∞ and 0% have different widths
    /// in the monospaced value font, the rendered image widths must differ.
    /// Single-char shortName so value width (∞ vs 0%) dominates slot width.
    /// Otherwise a wide shortName like "TU" masks the difference via max().
    func testUnlimitedSlotWidthDiffersFromZeroPercentSlot() {
        let unlimitedSlot = makeUnlimitedSlot(uuid: "ul-slot", shortName: "U")
        let zeroPercentSlot = makeSlot(
            uuid: "zero-slot",
            colorState: .normal,
            instanceType: .quota(percent: 0, usageValue: "0", limitValue: "", cycleRemainingSeconds: nil),
            shortName: "U"
        )

        let ulImage = renderer.render(
            slotViewDataList: [unlimitedSlot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        let zpImage = renderer.render(
            slotViewDataList: [zeroPercentSlot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        XCTAssertEqual(ulImage.size.height, 22, accuracy: 0.1)
        XCTAssertEqual(zpImage.size.height, 22, accuracy: 0.1)
        XCTAssertGreaterThan(ulImage.size.width, 0)
        XCTAssertGreaterThan(zpImage.size.width, 0)
        // "∞" (1 monospaced char) vs "0%" (2 monospaced chars) —
        // widths must differ. If equal, the unlimited check is likely broken.
        XCTAssertNotEqual(ulImage.size.width, zpImage.size.width, accuracy: 0.1,
                          "Unlimited slot (∞) must differ in width from 0% slot")
    }

    /// Unlimited slot snapshot — golden reference for the ∞ rendering.
    func testSnapshotUnlimitedNormal() {
        let slot = makeUnlimitedSlot(uuid: "snap-unlimited")
        renderer.updateBreathingState(slotViewDataList: [slot])

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "unlimited_normal")
    }
}
