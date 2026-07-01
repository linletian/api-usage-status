import SwiftUI

// MARK: - PeakPeriodBadge
//
// Small English pill rendered next to the "≈ ¥X.XX today" line on a DeepSeek
// card. Reuses the existing `Color.warningYellow` token so it visually matches
// the menu-bar peak overlay (yellow text + soft yellow capsule). Reads cleanly
// on the opaque popup surface in both Light and Dark appearance.
//
// `UsageCardView.balanceContent` wraps this in `TimelineView(.periodic(by: 60))`
// so the label flips automatically at the BJT window boundaries — no AppState
// plumbing needed.
//
// **No SwiftUI snapshot test**: per the project's existing testing convention
// (see `UsageCardViewTests` / `InstanceCardViewTests` /
// `EmptyStateGuideViewTests` file headers), `NSHostingController`-based
// snapshot tests fail in the current XCTest bundle because no `NSApplication`
// event loop is attached. The styling decision — yellow capsule, 9pt
// semibold — is intentionally fixed; the underlying label string is covered
// by `PeakPeriodTests.testLabelsAreEnglish`. If/when SwiftUI runtime tests
// are revived, add a snapshot test alongside the existing pattern.

struct PeakPeriodBadge: View {
    let period: PeakPeriod

    /// Sum of the `padding(.vertical, ...)` values below (2 + 2). Exposed so
    /// `MenuBarController` can add this to its pre-SwiftUI window-size
    /// estimate and stay in sync if the padding ever changes — see
    /// `MenuBarController.calculateContentHeight` (balance branch, DeepSeek
    /// provider). Updating the value here updates both call sites.
    static let totalVerticalPadding: CGFloat = 4

    var body: some View {
        Text(PeakSchedule.label(for: period))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.warningYellow)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.warningYellow.opacity(0.25))
            )
    }
}