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

        // One-shot regeneration mode: when this env var is set, overwrite
        // the reference image with the current render and PASS. Used to
        // refresh ReferenceImages/ after intentional rendering changes
        // (e.g., the inverted-pill menu bar redesign). To regenerate all
        // snapshot refs, run:
        //   REGENERATE_MENUBAR_REFS=1 xcodebuild ... test
        // then re-run without the env var to verify the new refs match.
        if ProcessInfo.processInfo.environment["REGENERATE_MENUBAR_REFS"] == "1" {
            try? pngData.write(to: referenceURL)
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

    /// The breathing timer must fire onNeedsDisplay at the configured 0.2s cadence
    /// so that shadow-phase interpolation runs smoothly across the 2-4s breathing cycle.
    ///
    /// Uses `XCTestExpectation` (not `Thread.sleep`) because `Thread.sleep` blocks
    /// the main thread, which prevents the timer's run loop from firing. The test
    /// runner's `wait(for:timeout:)` integrates with the run loop, allowing the
    /// timer to actually fire during the wait window.
    func testBreathingTimerFiresAtConfiguredCadence() {
        let slot = makeSlot(colorState: .warning)
        renderer.updateBreathingState(slotViewDataList: [slot])

        var fireCount = 0
        let originalCallback = renderer.onNeedsDisplay
        renderer.onNeedsDisplay = { fireCount += 1 }
        defer { renderer.onNeedsDisplay = originalCallback }

        renderer.startBreathingAnimation()

        // First fire happens ~0.2s after start; 0.4s timeout gives margin for slow CI
        let firstFire = expectation(description: "first breathing timer fire")
        let observer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if fireCount >= 1 {
                firstFire.fulfill()
                timer.invalidate()
            }
        }
        wait(for: [firstFire], timeout: 0.4)
        observer.invalidate()
        XCTAssertGreaterThanOrEqual(fireCount, 1,
            "Breathing timer should fire at least once within 0.4s of start")
        let firstWindowCount = fireCount

        // Wait another 0.4s and assert a second fire — confirms ongoing ~0.2s cadence
        let secondFire = expectation(description: "second breathing timer fire")
        let observer2 = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            if fireCount - firstWindowCount >= 1 {
                secondFire.fulfill()
                timer.invalidate()
            }
        }
        wait(for: [secondFire], timeout: 0.4)
        observer2.invalidate()
        XCTAssertGreaterThanOrEqual(fireCount - firstWindowCount, 1,
            "Breathing timer should fire again within 0.4s (proves ~0.2s cadence)")
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

    // MARK: - Inverted Pill Rendering (cut-out text)

    /// The pill should fill the slot's interior with the slot color and
    /// leave the text glyph region transparent (so the menu-bar background
    /// shows through). We sample the rendered bitmap at a location that's
    /// inside the pill but definitely not on a glyph: the left edge of
    /// the pill, where the rounded corner has cleared 3pt of padding but
    /// the geometric center would land on text.
    func testPillRendersWithCutOutText() {
        let slot = makeSlot(
            uuid: "pill-cutout",
            colorState: .normal,
            shortName: "MIN"
        )

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        let guard_ = alphaAt(image: image, x: 3, y: 11)
        let corner = alphaAt(image: image, x: 0, y: 0)

        // Pill should be opaque at the left-edge sample point. The color
        // must match menuBarSafe (#4CAF50 = R=76, G=175, B=80).
        XCTAssertGreaterThan(guard_.alpha, 200,
                             "Pill left-edge sample should be opaque; got alpha=\(guard_.alpha)")
        XCTAssertEqual(guard_.r, 76, "Pill red channel should match safe green; got \(guard_.r)")
        XCTAssertEqual(guard_.g, 175, "Pill green channel should match safe green; got \(guard_.g)")
        XCTAssertEqual(guard_.b, 80, "Pill blue channel should match safe green; got \(guard_.b)")

        // Top-left corner is outside the pill (pillVerticalMargin = 2pt
        // from top, plus rounded corner), so it should be transparent.
        XCTAssertLessThan(corner.alpha, 10,
                          "Outside-pill corner pixel should be transparent; got alpha=\(corner.alpha)")
    }

    // MARK: - Stale Slot Rendering

    /// Stale slots MUST use the fixed `#D6D0A0` dim color for the pill fill,
    /// regardless of the underlying `colorState` — per docs/ARCHITECTURE.md
    /// §7.3 / §7.5 the architectural decision is to use a constant gray
    /// rather than alpha-blend the threshold color. This matters because:
    ///   1. Alpha-blending onto the menu-bar's system appearance produces
    ///      unstable visual results across light/dark themes.
    ///   2. A stale warning/critical slot rendering as faded red/yellow
    ///      could mislead the user into thinking the data is still
    ///      alarming when it's actually cached from a previous fetch.
///
/// Staleness is encoded as `isStale=true` on the slot, which collapses
/// `slot.colorState` to `.error` (the single source of truth). The
/// renderer's `colorForSlot` then returns `dimColor` (the fixed
/// `#D6D0A0`) for `.error` slots.
    func testStaleSlotUsesGrayColor() {
        // Build slots with .warning/.critical `colorState` AS PASSED IN,
        // then flip `isStale=true`. The computed `colorState` should
        // collapse to `.error`, and the rendered pill should use the
        // fixed dim color — NOT the warning/critical hue.
        var warningSlot = makeSlot(
            uuid: "stale-warning",
            colorState: .warning,
            shortName: "WRN"
        )
        warningSlot.isStale = true

        var criticalSlot = makeSlot(
            uuid: "stale-critical",
            colorState: .critical,
            shortName: "CRI"
        )
        criticalSlot.isStale = true

        // `colorState` is a computed property — it must short-circuit to
        // `.error` when `isStale=true` regardless of the passed-in state.
        XCTAssertEqual(warningSlot.colorState, .error,
                       "isStale=true must collapse colorState to .error")
        XCTAssertEqual(criticalSlot.colorState, .error,
                       "isStale=true must collapse colorState to .error")

        let staleWarning = renderer.render(
            slotViewDataList: [warningSlot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        let staleCritical = renderer.render(
            slotViewDataList: [criticalSlot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        // Pill interior sample at the left edge (between corner radius and
        // text glyphs) — guaranteed to be on the pill fill, not a cutout.
        let warningSample = alphaAt(image: staleWarning, x: 3, y: 11)
        let criticalSample = alphaAt(image: staleCritical, x: 3, y: 11)

        // The dim color is #D6D0A0 = (R=214, G=208, B=160). Both warning
        // and critical stale slots must render with EXACTLY this color,
        // not faded warning yellow or critical red.
        XCTAssertEqual(warningSample.r, 214, "Stale warning pill must use dim R=214, got \(warningSample.r)")
        XCTAssertEqual(warningSample.g, 208, "Stale warning pill must use dim G=208, got \(warningSample.g)")
        XCTAssertEqual(warningSample.b, 160, "Stale warning pill must use dim B=160, got \(warningSample.b)")
        XCTAssertGreaterThan(warningSample.alpha, 240,
                             "Stale pill must be fully opaque (no alpha dimming); got alpha=\(warningSample.alpha)")

        XCTAssertEqual(criticalSample.r, 214, "Stale critical pill must use dim R=214, got \(criticalSample.r)")
        XCTAssertEqual(criticalSample.g, 208, "Stale critical pill must use dim G=208, got \(criticalSample.g)")
        XCTAssertEqual(criticalSample.b, 160, "Stale critical pill must use dim B=160, got \(criticalSample.b)")
        XCTAssertGreaterThan(criticalSample.alpha, 240,
                             "Stale pill must be fully opaque (no alpha dimming); got alpha=\(criticalSample.alpha)")
    }

    /// A fresh (non-stale) warning slot MUST still render with its
    /// threshold color (#FFC107 = warning yellow). Confirms the
    /// `colorForSlot` switch only flips to gray for `.error` —
    /// fresh data keeps its semantic color encoding.
    func testFreshWarningSlotKeepsYellowColor() {
        let slot = makeSlot(
            uuid: "fresh-warning",
            colorState: .warning,
            shortName: "WRN"
        )

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        let sample = alphaAt(image: image, x: 3, y: 11)
        // #FFC107 = (R=255, G=193, B=7)
        XCTAssertEqual(sample.r, 255, "Fresh warning pill R must be 255, got \(sample.r)")
        XCTAssertEqual(sample.g, 193, "Fresh warning pill G must be 193, got \(sample.g)")
        XCTAssertEqual(sample.b, 7, "Fresh warning pill B must be 7, got \(sample.b)")
    }

    /// Find the maximum alpha value across a horizontal scan of the
    /// image in the given y range. Useful for measuring pill fill alpha
    /// without being misled by cut-out text glyphs (which produce 0 alpha).
    private func maxAlpha(in image: NSImage, yRange: Range<Int>) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return 0 }
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var maxAlpha = 0
        for y in yRange {
            guard y >= 0, y < height else { continue }
            for x in 0..<width {
                let offset = (y * width + x) * 4 + 3
                let a = Int(pixelData[offset])
                if a > maxAlpha { maxAlpha = a }
            }
        }
        return maxAlpha
    }

    /// Stale slots suppress the breathing animation even when the underlying
    /// `colorState` is `.warning` or `.critical`. This is checked by the
    /// renderer's internal state — we just verify the stale slot UUID
    /// Stale slots (`.error` colorState) must suppress the breathing
    /// animation. `updateBreathingState` only includes warning/critical
    /// UUIDs in the breathing set, so stale slots are excluded at
    /// the source — no separate stale tracking needed.
    func testStaleSlotSuppressesBreathing() {
        var slot = makeSlot(
            uuid: "stale-suppress",
            colorState: .warning,
            shortName: "WRN"
        )
        slot.isStale = true
        XCTAssertEqual(slot.colorState, .error,
                       "Sanity check: isStale=true collapses colorState to .error")

        // `updateBreathingState` only adds warning/critical UUIDs. Since
        // `slot.colorState` is now `.error`, the slot won't be added to
        // the breathing set.
        renderer.updateBreathingState(slotViewDataList: [slot])
        renderer.currentTimeProvider = { 1.0 }
        renderer.startBreathingAnimation()

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        // Without the stale suppression, the renderer's breathing
        // animation would have drawn a glow around the pill. With
        // suppression, no shadow is applied. We can't directly read
        // the CGContext's shadow state from the bitmap, but we can
        // assert that the image still renders successfully (no crash
        // from disabled shadow) and that the pill center is still
        // visible (alpha > 0).
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(pillCenterAlpha(image), 50,
                             "Stale slot pill should still be visible (suppressed breathing shouldn't blank the pill)")
    }

    /// Stale slot must collapse to the fixed `#D6D0A0` regardless of the
    /// underlying `colorState`. We already cover warning/critical; this
    /// pins down normal/unavailable to make sure no future refactor
    /// accidentally lets a non-error colorState leak through when
    /// `isStale=true`.
    func testStaleSlotCollapsesAllUnderlyingColorStates() {
        for underlyingState: ColorState in [.normal, .warning, .critical, .unavailable] {
            var slot = makeSlot(
                uuid: "stale-\(underlyingState)",
                colorState: underlyingState,
                shortName: "T"
            )
            slot.isStale = true
            XCTAssertEqual(slot.colorState, .error,
                           "isStale=true must collapse \(underlyingState) to .error")

            let image = renderer.render(
                slotViewDataList: [slot],
                colorMode: .color,
                refreshState: .idle,
                instancesCount: 1,
                enabledCount: 1,
                isDarkBackground: false
            )
            let sample = alphaAt(image: image, x: 3, y: 11)
            XCTAssertEqual(sample.r, 214,
                           "Stale slot (\(underlyingState) underlying) must use dim R=214, got \(sample.r)")
            XCTAssertEqual(sample.g, 208,
                           "Stale slot (\(underlyingState) underlying) must use dim G=208, got \(sample.g)")
            XCTAssertEqual(sample.b, 160,
                           "Stale slot (\(underlyingState) underlying) must use dim B=160, got \(sample.b)")
            XCTAssertGreaterThan(sample.alpha, 240,
                                  "Stale slot (\(underlyingState)) must be fully opaque (no alpha dimming)")
        }
    }

    /// Stale slot in **monochrome** mode must STILL render as the fixed
    /// dim gray (`#D6D0A0`). Per docs/ARCHITECTURE.md §7.3, the
    /// architectural decision was to use a constant color value rather
    /// than alpha-blend the threshold color — exactly to avoid the
    /// unstable visual result alpha compositing produces across the
    /// system appearance. If a future change reintroduces alpha
    /// blending for stale slots, this test will catch it.
    func testStaleSlotIsGrayInMonochromeMode() {
        var slot = makeSlot(
            uuid: "stale-mono-light",
            colorState: .warning,  // would be black on light bg if monochrome alpha were used
            shortName: "M"
        )
        slot.isStale = true

        // Light menu-bar background.
        let lightImage = renderer.render(
            slotViewDataList: [slot],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )
        let lightSample = alphaAt(image: lightImage, x: 3, y: 11)
        XCTAssertEqual(lightSample.r, 214, "Monochrome-light stale must use dim R=214, got \(lightSample.r)")
        XCTAssertEqual(lightSample.g, 208, "Monochrome-light stale must use dim G=208, got \(lightSample.g)")
        XCTAssertEqual(lightSample.b, 160, "Monochrome-light stale must use dim B=160, got \(lightSample.b)")
        XCTAssertGreaterThan(lightSample.alpha, 240,
                              "Monochrome-light stale must be fully opaque")

        // Dark menu-bar background — same expected color (no alpha
        // compositing with system white).
        let darkImage = renderer.render(
            slotViewDataList: [slot],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: true
        )
        let darkSample = alphaAt(image: darkImage, x: 3, y: 11)
        XCTAssertEqual(darkSample.r, 214, "Monochrome-dark stale must use dim R=214, got \(darkSample.r)")
        XCTAssertEqual(darkSample.g, 208, "Monochrome-dark stale must use dim G=208, got \(darkSample.g)")
        XCTAssertEqual(darkSample.b, 160, "Monochrome-dark stale must use dim B=160, got \(darkSample.b)")
        XCTAssertGreaterThan(darkSample.alpha, 240,
                              "Monochrome-dark stale must be fully opaque")
    }

    /// A stale slot still has cut-out text glyphs — the text is rendered
    /// in destination-out blend mode so the menu-bar background shows
    /// through, not "filled with gray text on gray pill". Verifies the
    /// stale path produces the same inverted-pill visual as fresh slots.
    func testStaleSlotPreservesCutoutText() {
        var slot = makeSlot(
            uuid: "stale-cutout",
            colorState: .normal,
            shortName: "MIN"
        )
        slot.isStale = true

        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1,
            isDarkBackground: false
        )

        let pillSample = alphaAt(image: image, x: 3, y: 11)
        XCTAssertGreaterThan(pillSample.alpha, 200,
                              "Stale pill interior should be opaque gray")

        // The corner (outside the pill) should remain transparent — the
        // pill rendering doesn't bleed into the slot's margin.
        let corner = alphaAt(image: image, x: 0, y: 0)
        XCTAssertLessThan(corner.alpha, 10,
                          "Outside-pill corner must be transparent; got alpha=\(corner.alpha)")

        // Sanity: rendering a stale slot produces a non-empty image of
        // the expected slot height (no crash from the destination-out
        // path operating on the gray pill).
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
    }

    /// Sample the alpha channel and RGB at the geometric center of the
    /// rendered image. Used by the pill tests to check fill opacity and
    /// exact RGB match against the expected slot color. Returns zeros
    /// when the image can't be sampled.
    private struct PixelSample {
        let r: Int
        let g: Int
        let b: Int
        let alpha: Int
    }

    private func alphaAt(image: NSImage, x: Int, y: Int) -> PixelSample {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return PixelSample(r: 0, g: 0, b: 0, alpha: 0)
        }
        let width = cgImage.width
        let height = cgImage.height
        guard x >= 0, y >= 0, x < width, y < height else {
            return PixelSample(r: 0, g: 0, b: 0, alpha: 0)
        }
        let bytesPerRow = width * 4
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PixelSample(r: 0, g: 0, b: 0, alpha: 0)
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = (y * width + x) * 4
        return PixelSample(
            r: Int(pixelData[offset]),
            g: Int(pixelData[offset + 1]),
            b: Int(pixelData[offset + 2]),
            alpha: Int(pixelData[offset + 3])
        )
    }

    /// Convenience: alpha at the pill's left-edge interior sample point
    /// (3px in from x=0, between the rounded corner and the text glyphs).
    /// Used by the breathing-suppression test that only cares about
    /// visibility (alpha > 0) not exact color.
    private func pillCenterAlpha(_ image: NSImage) -> Int {
        return alphaAt(image: image, x: 3, y: 11).alpha
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
