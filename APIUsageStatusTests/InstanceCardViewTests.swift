import XCTest
@testable import APIUsageStatus

/// Tests for `InstanceCardView`.
///
/// **Why these are logic tests, not view-hierarchy tests.** Same rationale
/// as `EmptyStateGuideViewTests`: `NSHostingController` throws
/// `NSInternalInconsistencyException` in the XCTest bundle, and
/// `NSHostingView` no longer exposes AppKit subviews for SwiftUI primitives
/// on current macOS (spike-verified 2026-07-19), so the original
/// walk-the-hierarchy / `performClick` approach cannot work. See
/// `UsageCardViewTests` for the precedent.
///
/// Pinned without rendering (the view's computed members are internal for
/// exactly this purpose):
/// - display-name resolution (empty → "Untitled")
/// - subtitle mapping (`Provider.displayName · dimension`, unknown provider
///   → `.capitalized`)
/// - `trackingBinding` get/set contract (the tracking toggle's wiring)
///
/// **Coverage lost** vs. the original suite: rendered presence of the
/// shortName badge / tracking switch / edit / delete buttons, and
/// performClick-driven edit/delete wiring.
final class InstanceCardViewTests: XCTestCase {

    // MARK: - Fixtures

    private func makeView(
        displayName: String = "Test Instance",
        shortName: String = "TI",
        provider: String = "minimax",
        dimension: String = "general",
        trackingEnabled: Bool = true,
        onToggleTracking: @escaping () -> Void = {}
    ) -> InstanceCardView {
        let instance = Instance(
            provider: provider,
            dimension: dimension,
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: "test-key-ref",
            enabled: trackingEnabled,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
        return InstanceCardView(
            instance: instance,
            onEdit: {},
            onDelete: {},
            onToggleTracking: onToggleTracking
        )
    }

    // MARK: - Display name

    /// The display name renders verbatim when set.
    func testDisplayNameUsesInstanceValue() {
        XCTAssertEqual(makeView(displayName: "My API").displayName, "My API")
    }

    /// An empty display name falls back to "Untitled" — the card must never
    /// render a blank title row.
    func testDisplayNameFallsBackToUntitled() {
        XCTAssertEqual(makeView(displayName: "").displayName, "Untitled")
    }

    // MARK: - Subtitle

    /// The subtitle must use `Provider.displayName` for known providers.
    func testSubtitleUsesProviderDisplayName() {
        XCTAssertEqual(
            makeView(provider: "deepseek", dimension: "balance").subtitle,
            "DeepSeek · balance"
        )
    }

    func testSubtitleUsesMiniMaxDisplayName() {
        XCTAssertEqual(
            makeView(provider: "minimax", dimension: "general").subtitle,
            "MiniMax · general"
        )
    }

    /// Unknown providers fall back to `.capitalized`.
    func testSubtitleCapitalizesUnknownProvider() {
        XCTAssertEqual(
            makeView(provider: "somecloud", dimension: "usage").subtitle,
            "Somecloud · usage"
        )
    }

    // MARK: - Tracking toggle binding

    /// The toggle's get must mirror `instance.trackingEnabled`.
    func testTrackingBindingGetMirrorsInstance() {
        XCTAssertTrue(makeView(trackingEnabled: true).trackingBinding.wrappedValue)
        XCTAssertFalse(makeView(trackingEnabled: false).trackingBinding.wrappedValue)
    }

    /// Any set on the toggle binding must forward to `onToggleTracking`
    /// exactly once — the card itself never decides the toggle outcome.
    func testTrackingBindingSetInvokesOnToggleTracking() {
        var callCount = 0
        let view = makeView(onToggleTracking: { callCount += 1 })

        view.trackingBinding.wrappedValue = false

        XCTAssertEqual(callCount, 1, "Setting the toggle must invoke onToggleTracking exactly once")
    }
}
