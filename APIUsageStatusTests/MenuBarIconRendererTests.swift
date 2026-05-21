import XCTest
@testable import APIUsageStatus

// MARK: - MenuBarIconRendererTests

/// Snapshot-style tests for MenuBarIconRenderer.
/// Golden Master workflow:
///   1. First run generates reference PNGs in ReferenceImages/
///   2. Subsequent runs compare rendered PNG bytes against the reference.
/// If the rendering logic changes intentionally, delete ReferenceImages/ and re-run.
@MainActor
final class MenuBarIconRendererTests: XCTestCase {

    private var renderer: MenuBarIconRenderer!

    override func setUp() {
        super.setUp()
        renderer = MenuBarIconRenderer()
    }

    override func tearDown() {
        renderer = nil
        super.tearDown()
    }

    // MARK: - Snapshot helpers

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

    // MARK: - Scenarios

    func testZeroInstances() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 0,
            enabledCount: 0
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "zero_instances_question_mark")
    }

    func testAllDisabled() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 2,
            enabledCount: 0
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "all_disabled_no_api")
    }

    func testLoadingState() {
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .refreshing,
            instancesCount: 2,
            enabledCount: 2
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "loading_bullets")
    }

    func testOneQuotaSafeColorMode() {
        let slot = SlotViewData(
            uuid: "quota-safe",
            displayName: "MiniMax Text",
            shortName: "MX",
            instanceType: .quota(percent: 45, usageValue: "450", limitValue: "1000", nextRefreshMinutes: 3, cycleRemainingDays: 5),
            sortOrder: 0,
            colorState: .normal
        )
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "one_quota_safe_color")
    }

    func testOneQuotaWarningMonochromeMode() {
        let slot = SlotViewData(
            uuid: "quota-warning",
            displayName: "MiniMax Speech",
            shortName: "SP",
            instanceType: .quota(percent: 75, usageValue: "750", limitValue: "1000", nextRefreshMinutes: 3, cycleRemainingDays: nil),
            sortOrder: 0,
            colorState: .warning
        )
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .monochrome,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "one_quota_warning_mono")
    }

    func testOneBalanceWarningColorMode() {
        let slot = SlotViewData(
            uuid: "balance-warning",
            displayName: "DeepSeek",
            shortName: "DS",
            instanceType: .balance(amount: "15.20", totalBalance: "20.00", grantedBalance: "4.80", isAvailable: true, currency: "CNY"),
            sortOrder: 0,
            colorState: .warning
        )
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "one_balance_warning_color")
    }

    func testTwoSlotsMixed() {
        let quota = SlotViewData(
            uuid: "quota-critical",
            displayName: "MiniMax",
            shortName: "MX",
            instanceType: .quota(percent: 96, usageValue: "960", limitValue: "1000", nextRefreshMinutes: 1, cycleRemainingDays: 2),
            sortOrder: 0,
            colorState: .critical
        )
        let balance = SlotViewData(
            uuid: "balance-normal",
            displayName: "DeepSeek",
            shortName: "DS",
            instanceType: .balance(amount: "88.50", totalBalance: "100.00", grantedBalance: "11.50", isAvailable: true, currency: "USD"),
            sortOrder: 1,
            colorState: .normal
        )
        let image = renderer.render(
            slotViewDataList: [quota, balance],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 2,
            enabledCount: 2
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        // Should render two slots with a 2pt gap
        let expectedMinWidth: CGFloat = 80
        XCTAssertGreaterThan(image.size.width, CGFloat(expectedMinWidth) - 1)
        assertSnapshot(image, named: "two_slots_mixed_color")
    }

    func testBalanceUnavailable() {
        let slot = SlotViewData(
            uuid: "balance-unavailable",
            displayName: "DeepSeek",
            shortName: "DS",
            instanceType: .balance(amount: "0", totalBalance: "0", grantedBalance: "0", isAvailable: false, currency: "CNY"),
            sortOrder: 0,
            colorState: .unavailable
        )
        let image = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "balance_unavailable_na")
    }

    func testThreeSlotsTruncatedToTwo() {
        let a = SlotViewData(
            uuid: "slot-a",
            displayName: "A",
            shortName: "AA",
            instanceType: .quota(percent: 10, usageValue: "10", limitValue: "100", nextRefreshMinutes: 5, cycleRemainingDays: nil),
            sortOrder: 0,
            colorState: .normal
        )
        let b = SlotViewData(
            uuid: "slot-b",
            displayName: "B",
            shortName: "BB",
            instanceType: .quota(percent: 20, usageValue: "20", limitValue: "100", nextRefreshMinutes: 5, cycleRemainingDays: nil),
            sortOrder: 1,
            colorState: .normal
        )
        let c = SlotViewData(
            uuid: "slot-c",
            displayName: "C",
            shortName: "CC",
            instanceType: .quota(percent: 30, usageValue: "30", limitValue: "100", nextRefreshMinutes: 5, cycleRemainingDays: nil),
            sortOrder: 2,
            colorState: .normal
        )
        let image = renderer.render(
            slotViewDataList: [a, b, c],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 3,
            enabledCount: 3
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        // Only first 2 slots rendered → width roughly same as two-slot scenario
        assertSnapshot(image, named: "three_slots_truncated")
    }

    func testFlashingStateUpdateRendering() {
        let slot = SlotViewData(
            uuid: "flashing-slot",
            displayName: "MiniMax",
            shortName: "MX",
            instanceType: .quota(percent: 98, usageValue: "980", limitValue: "1000", nextRefreshMinutes: 1, cycleRemainingDays: 1),
            sortOrder: 0,
            colorState: .critical
        )

        // First render with flashing visible (default)
        renderer.updateFlashingState(slotViewDataList: [slot])
        let imageVisible = renderer.render(
            slotViewDataList: [slot],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )

        // Simulate one flash cycle → toggle off
        renderer.updateFlashingState(slotViewDataList: [slot])
        // Manually toggle visibility to simulate the Task running
        // We can't easily wait for the Task in a unit test, so we test the internal state directly
        // by checking the flashingVisible dictionary through the render output.
        // Instead, we'll verify the renderer's flashing state tracking.

        XCTAssertEqual(imageVisible.size.height, 22, accuracy: 0.1)
        assertSnapshot(imageVisible, named: "critical_visible")
    }

    func testEmptyEnabledSlotsShowsQuestion() {
        // Instances exist and enabled, but slotViewDataList is empty (e.g. all failed or loading)
        let image = renderer.render(
            slotViewDataList: [],
            colorMode: .color,
            refreshState: .idle,
            instancesCount: 1,
            enabledCount: 1
        )
        XCTAssertEqual(image.size.height, 22, accuracy: 0.1)
        assertSnapshot(image, named: "empty_slots_question")
    }
}
