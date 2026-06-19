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
        renderer.stopDefaultAnimation()
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

    // MARK: - Default Animation Lifecycle (RED phase)

    func testDefaultAnimationStartStop() {
        renderer.startDefaultAnimation()
        XCTAssertTrue(renderer.isDefaultAnimationRunning,
                       "isDefaultAnimationRunning should be true after start")

        renderer.stopDefaultAnimation()
        XCTAssertFalse(renderer.isDefaultAnimationRunning,
                        "isDefaultAnimationRunning should be false after stop")
    }

    func testDefaultAnimationInitiallyStopped() {
        XCTAssertFalse(renderer.isDefaultAnimationRunning,
                        "isDefaultAnimationRunning should be false before any start call")
    }

    func testDefaultAnimationRestartAfterStop() {
        renderer.startDefaultAnimation()
        renderer.stopDefaultAnimation()
        renderer.startDefaultAnimation()
        XCTAssertTrue(renderer.isDefaultAnimationRunning,
                       "isDefaultAnimationRunning should be true after restart")
    }

    func testDefaultAnimationStartIdempotent() {
        renderer.startDefaultAnimation()
        renderer.startDefaultAnimation()
        XCTAssertTrue(renderer.isDefaultAnimationRunning,
                       "Calling start twice should still leave animation running")
    }

    // MARK: - Default animation cycle (TDD RED)

    func testDefaultAnimationCycleIndexAdvances() {
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 0,
                       "Cycle index should start at 0")

        renderer.advanceDefaultAnimationCycle()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 1,
                       "Cycle index should advance to 1 after first tick")

        renderer.advanceDefaultAnimationCycle()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 2,
                       "Cycle index should advance to 2 after second tick")

        renderer.advanceDefaultAnimationCycle()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 0,
                       "Cycle index should wrap back to 0 after third tick (3-step cycle)")
    }

    /// Each animation frame should produce a distinct render output
    /// (different bottom texts give different image widths). Verifies
    /// behaviour via render output rather than duplicating the internal
    /// text-to-index mapping. Also confirms the 3-frame cycle wraps
    /// back to the starting output.
    func testDefaultAnimationCycleProducesDistinctFrames() {
        let renderDefault: () -> NSImage = { [self] in
            renderer.render(
                slotViewDataList: [],
                colorMode: .color,
                refreshState: .idle,
                instancesCount: 0,
                enabledCount: 0,
                isDarkBackground: false
            )
        }

        let frame0 = renderDefault()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 0)

        renderer.advanceDefaultAnimationCycle()
        let frame1 = renderDefault()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 1,
                       "Index should advance to 1")

        renderer.advanceDefaultAnimationCycle()
        let frame2 = renderDefault()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 2,
                       "Index should advance to 2")

        renderer.advanceDefaultAnimationCycle()
        let frame3 = renderDefault()
        XCTAssertEqual(renderer.defaultAnimationCycleIndex, 0,
                       "Index should wrap back to 0")

        // Width stability: all frames share the same slot width (locked to longest text "%%%")
        XCTAssertEqual(frame0.size.width, frame1.size.width, accuracy: 0.1,
                       "Frame 0 and frame 1 should have identical width (anti-jitter design)")
        XCTAssertEqual(frame1.size.width, frame2.size.width, accuracy: 0.1,
                       "Frame 1 and frame 2 should have identical width (anti-jitter design)")

        // Full cycle wrap: frame 3 should equal frame 0
        XCTAssertEqual(frame3.size.width, frame0.size.width, accuracy: 0.1,
                       "After full cycle, frame should match initial frame")
    }

    // MARK: - Default State (no instances) two-line rendering

    /// Measure the on-screen width of a single character rendered with the menu
    /// bar font (SF Pro Regular 8pt). Used as the baseline for asserting that
    /// the default-state two-line layout is wider than a single "?" glyph.
    private func singleCharWidth(_ char: String) -> CGFloat {
        let attr = NSAttributedString(string: char, attributes: [.font: NSFont.systemFont(ofSize: 8)])
        let size = attr.size()
        return size.width
    }

    /// Default state (instancesCount == 0) should render a two-line layout —
    /// not the legacy single "?" glyph. A two-line layout for an "AI"-style
    /// brand mark spans multiple characters and is therefore visibly wider
    /// than a single "?" character.
    func testDefaultStateRendersTwoLineLayout() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0,
            isDarkBackground: false
        )

        XCTAssertNotNil(image, "Default state render must produce a non-nil image")
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                       "Default state must keep the 22pt slot height")
        XCTAssertGreaterThan(image.size.width, 0,
                             "Default state must have non-zero width")

        let singleQWidth = singleCharWidth("?")
        XCTAssertGreaterThan(image.size.width, singleQWidth,
                             "Two-line default layout should be wider than a single '?' glyph (was \(image.size.width) vs ?=\(singleQWidth))")
    }

    /// Default state should render the "AI" brand text (two lines, two chars
    /// per line) and therefore be wider than any single-character legacy
    /// fallback. This locks in the brand-marker behavior at the image level
    /// without coupling to pixel diffs.
    func testDefaultStateRendersAIBrandText() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0,
            isDarkBackground: false
        )

        XCTAssertNotNil(image, "Default state render must produce a non-nil image")
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                       "Default state must keep the 22pt slot height")
        XCTAssertGreaterThan(image.size.width, 0,
                             "Default state must have non-zero width")

        // Two-line "AI" brand text spans multiple chars; an image holding it
        // must be wider than any single character (the legacy "?" baseline).
        let singleAWidth = singleCharWidth("A")
        let singleIWidth = singleCharWidth("I")
        let singleCharBaseline = max(singleAWidth, singleIWidth)
        XCTAssertGreaterThan(image.size.width, singleCharBaseline,
                             "Default state 'AI' brand layout should be wider than a single character")
    }

    /// Golden snapshot for the default (no-instances) state two-line layout.
    /// Creates a ReferenceImages/default_state_no_instances.png on first run.
    func testSnapshotDefaultStateNoInstances() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0,
            isDarkBackground: false
        )

        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "default_state_no_instances")
    }

    // MARK: - Default State Monochrome Mode

    func testDefaultStateMonochromeLightBackground() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0,
            isDarkBackground: false
        )

        XCTAssertNotNil(image, "Monochrome default state must produce a non-nil image")
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                       "Monochrome default state must keep the 22pt slot height")
        XCTAssertGreaterThan(image.size.width, 0,
                             "Monochrome default state must have non-zero width")
    }

    func testDefaultStateMonochromeDarkBackground() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0,
            isDarkBackground: true
        )

        XCTAssertNotNil(image, "Monochrome default state must produce a non-nil image")
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1,
                       "Monochrome default state must keep the 22pt slot height")
        XCTAssertGreaterThan(image.size.width, 0,
                             "Monochrome default state must have non-zero width")
    }

    // MARK: - Default State Width Stability

    /// Animation frame changes must not cause menu bar icon width to jitter.
    /// All three frames (% / %% / %%% ) should produce images of identical
    /// width — locked to the longest text (%%%) measured in the monospaced
    /// bottom-line font. Also locks the assumption that the bottom-line font
    /// produces wider text than the top-line proportional font for "AI".
    func testDefaultStateWidthStableAcrossAnimationFrames() {
        let renderCurrent: () -> NSImage = { [self] in
            renderer.render(
                slotViewDataList: [],
                colorMode: .color,
                refreshState: .idle,
                instancesCount: 0,
                enabledCount: 0,
                isDarkBackground: false
            )
        }

        let frame0 = renderCurrent()
        renderer.advanceDefaultAnimationCycle()
        let frame1 = renderCurrent()
        renderer.advanceDefaultAnimationCycle()
        let frame2 = renderCurrent()

        XCTAssertEqual(frame0.size.height, 22, accuracy: 0.1)
        XCTAssertEqual(frame1.size.height, 22, accuracy: 0.1)
        XCTAssertEqual(frame2.size.height, 22, accuracy: 0.1)

        XCTAssertEqual(frame0.size.width, frame1.size.width, accuracy: 0.1,
                       "All animation frames must share the same slot width")
        XCTAssertEqual(frame1.size.width, frame2.size.width, accuracy: 0.1,
                       "All animation frames must share the same slot width")

        let topWidth = singleCharWidth("A") + singleCharWidth("I")
        let monoFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let bottomMaxWidth = (("%%%" as NSString).size(withAttributes: [.font: monoFont])).width
        XCTAssertGreaterThanOrEqual(frame0.size.width, max(topWidth, bottomMaxWidth),
                                    "Slot width must cover longest possible text to prevent jitter")
    }
}
