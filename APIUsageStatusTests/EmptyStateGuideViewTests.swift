import XCTest
@testable import APIUsageStatus

/// Tests for `EmptyStateGuideView`.
///
/// **Why these are copy-pinning tests, not view-hierarchy tests.**
/// This suite originally rendered the view through `NSHostingController` and
/// walked the AppKit hierarchy for `NSTextField` / `NSButton`. That approach
/// is dead in the XCTest bundle on current macOS:
/// 1. `NSHostingController(rootView:).loadView()` throws
///    `NSInternalInconsistencyException` (falls into the nib-loading path)
///    without a running app event loop.
/// 2. `NSHostingView` instantiates fine, but SwiftUI no longer materializes
///    AppKit subviews for `Text` / `Button`, so hierarchy walking finds
///    nothing (spike-verified 2026-07-19).
///
/// What remains pinnable without rendering is the exact product copy — the
/// strings are sourced from `EmptyStateGuideView.titleText` /
/// `.subtitleText` / `.ctaButtonLabel`, so these assertions fail if the copy
/// drifts. Same conversion rationale as `UsageCardViewTests` and
/// `InstanceCardViewTests`.
///
/// **Coverage lost** vs. the original suite: CTA-tap → `onAddInstance`
/// wiring via a rendered `NSButton` (a SwiftUI `Button(action:)` passthrough
/// that cannot be exercised without an AppKit host).
final class EmptyStateGuideViewTests: XCTestCase {

    /// The hero title must remain verbatim — it drives the empty-state
    /// messaging across the popover / settings surface.
    func testTitleCopyIsVerbatim() {
        XCTAssertEqual(EmptyStateGuideView.titleText, "No Instances Configured")
    }

    /// The subtitle must explain what the user can do next. The wording is
    /// part of the product spec, so it must not regress silently.
    func testSubtitleCopyIsVerbatim() {
        XCTAssertEqual(
            EmptyStateGuideView.subtitleText,
            "Add your first API instance to start monitoring usage"
        )
    }

    /// The CTA button must show the exact product-approved label.
    /// Changing this string is a product-level change, not a refactor.
    func testCTAButtonLabelIsVerbatim() {
        XCTAssertEqual(EmptyStateGuideView.ctaButtonLabel, "Add Your First Instance")
    }

    /// The view must store the supplied closure unchanged — the empty state
    /// exists to route the user into the add-instance flow, and a dropped
    /// closure would strand the user on this surface.
    func testOnAddInstanceClosureIsWiredThrough() {
        var callCount = 0
        let view = EmptyStateGuideView(onAddInstance: { callCount += 1 })

        view.onAddInstance()

        XCTAssertEqual(callCount, 1, "onAddInstance must be invoked exactly once")
    }
}
