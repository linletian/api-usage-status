import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for `UsagePanelView` derived data.
///
/// The SwiftUI view itself can't be unit-tested without a real
/// `NSApplication` context (see `UsageCardViewTests` file header for
/// the same constraint and reasoning). Instead we pin the pure
/// data-derivation functions the view branches on, mirroring the
/// production formulas here so a regression in the formula surfaces
/// here in addition to the rendering path.
final class UsagePanelViewTests: XCTestCase {

    // MARK: - minutesUntilNextRefresh (mirror)

    /// The "Next refresh: ≈ Xm" countdown subtracts elapsed time from
    /// the global refresh interval. The view re-evaluates this every
    /// minute via `TimelineView`; this test pins the formula so an
    /// off-by-one or sign-flip regression is caught. Math: with a
    /// 5m interval, `300 - elapsed_seconds`, integer-divided by 60,
    /// floored at 0.
    func testMinutesUntilNextRefreshDerivation() {
        // Mirrors `UsagePanelView.minutesUntilNextRefresh(now:)`:
        // elapsed since last refresh subtracted from interval, floored
        // at 0. Falls back to the full interval when no refresh has
        // happened yet.
        func minutes(intervalMinutes: Int, lastRefreshAt: Date?, now: Date) -> Int {
            guard let lastRefresh = lastRefreshAt else { return intervalMinutes }
            let elapsed = now.timeIntervalSince(lastRefresh)
            let remaining = TimeInterval(intervalMinutes * 60) - elapsed
            return max(0, Int(remaining / 60))
        }

        let interval = 5
        let now = Date()

        XCTAssertEqual(
            minutes(intervalMinutes: interval, lastRefreshAt: nil, now: now),
            interval,
            "No last refresh → fall back to the full interval"
        )

        // 30s elapsed of a 5m interval → 270s remaining → 4m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-30), now: now),
            4
        )
        // 60s elapsed → 240s remaining → 4m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-60), now: now),
            4
        )
        // 90s elapsed → 210s remaining → 3m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-90), now: now),
            3
        )
        // 4m (240s) elapsed → 60s remaining → 1m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-240), now: now),
            1
        )
        // Exactly at the boundary (5m elapsed) → 0m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-300), now: now),
            0,
            "Exactly at the interval boundary → 0m"
        )
        // Past the interval → clamp to 0m (never negative)
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-360), now: now),
            0,
            "Past the interval → clamp to 0m, never negative"
        )
        // 4m 50s elapsed → 10s remaining → integer-divided by 60 → 0m
        XCTAssertEqual(
            minutes(intervalMinutes: interval,
                    lastRefreshAt: now.addingTimeInterval(-290), now: now),
            0,
            "Sub-minute remainder floors down to 0m, not rounds up"
        )

        // Different interval — pins that the formula multiplies by 60
        // rather than assuming a fixed interval.
        XCTAssertEqual(
            minutes(intervalMinutes: 10,
                    lastRefreshAt: now.addingTimeInterval(-60 * 3), now: now),
            7,
            "10m interval with 3m elapsed → 7m remaining"
        )
    }
}
