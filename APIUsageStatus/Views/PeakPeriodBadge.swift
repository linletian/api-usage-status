import SwiftUI

// MARK: - PeakPeriodBadge
//
// Small English pill rendered next to the "≈ ¥X.XX today" line on a DeepSeek
// card. Two-tone: Peak uses `Color.warningYellow` (caution / higher rate);
// Off-Peak uses `Color.trackingOn` (green / lower rate). Each period pairs
// its tone with a matching 25% capsule fill so both states read as a clean
// monochromatic pill at 9pt on the opaque popup surface (Light and Dark
// appearance).
//
// `UsageCardView.balanceContent` wraps this in `TimelineView(.periodic(by: 60))`
// so the label flips automatically at the BJT window boundaries — no AppState
// plumbing needed.
//
// **No SwiftUI snapshot test**: per the project's existing testing convention
// (see `UsageCardViewTests` / `InstanceCardViewTests` /
// `EmptyStateGuideViewTests` file headers), `NSHostingController`-based
// snapshot tests fail in the current XCTest bundle because no `NSApplication`
// event loop is attached. The styling decision — period-keyed tone (yellow
// for peak, green for off-peak) with matching 25% capsule fill, 9pt
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

    /// Tones: peak → `warningYellow` (higher rate, caution), off-peak →
    /// `trackingOn` (lower rate, "good"). Paired with a matching 25%
    /// capsule fill in `body`.
    private var tone: Color {
        period == .peak ? Color.warningYellow : Color.trackingOn
    }

    var body: some View {
        Text(PeakSchedule.label(for: period))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(tone.opacity(0.25))
            )
    }
}
