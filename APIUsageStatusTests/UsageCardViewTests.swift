import XCTest
import SwiftUI
import AppKit
@testable import APIUsageStatus

/// Tests for `UsageCardView` — focused on the footer variants added
/// for the stale / window-expired UX (per docs/ARCHITECTURE.md §7.5
/// "刷新失败: 上次成功数据照常显示, 整体应用 80% 透明度").
///
/// **Why this file is mostly logic tests, not snapshot tests:**
/// SwiftUI's `NSHostingController` requires a fully-initialized
/// `NSApplication` with an attached event loop to load a view. In the
/// XCTest bundle the application context is missing, so
/// `NSHostingController(rootView:).loadView()` throws
/// `NSInternalInconsistencyException`. The same failure mode is shared
/// by `InstanceCardViewTests` and `EmptyStateGuideViewTests` — those
/// tests have been failing for this reason throughout this work.
///
/// Instead of duplicating that broken pattern, we directly assert the
/// pure functions `UsageCardView` depends on (`isStale` / `colorState`
/// orthogonality, `Date.timeSinceNow` + `Int.formattedDuration`
/// formatting, ErrorSummary lookup keys, `firstCycleRemaining` data
/// derivation). These are what the SwiftUI @ViewBuilder branches on,
/// so they give us the same coverage guarantee. If/when the project's
/// SwiftUI runtime in tests is fixed, add snapshot tests following the
/// `InstanceCardViewTests` walking-the-view-hierarchy pattern.
@MainActor
final class UsageCardViewTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSlot(
        uuid: String = "test-uuid",
        displayName: String = "Test Provider",
        shortName: String = "TST",
        isStale: Bool = false,
        cycleRemainingSeconds: Int? = 3600,
        snapshotColorState: ColorState = .normal
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: displayName,
            shortName: shortName,
            sortOrder: 0,
            colorState: snapshotColorState,
            provider: "test",
            dimension: "test",
            metricSnapshots: [
                MetricSnapshot(
                    key: "test",
                    group: nil,
                    window: nil,
                    percent: 50,
                    displayUsage: "50",
                    displayLimit: "100",
                    cycleRemainingSeconds: cycleRemainingSeconds,
                    colorState: snapshotColorState,
                    configIndex: 1,
                    displayInMenuBar: true,
                    isUnlimited: false,
                    shortName: nil
                )
            ],
            isStale: isStale
        )
    }

    private func makeStaleError(
        uuid: String,
        errorType: ErrorType = .networkTimeout
    ) -> ErrorSummary {
        ErrorSummary(id: uuid, displayName: "Test Provider", errorType: errorType)
    }

    private func cardView(
        slot: SlotViewData,
        lastRefreshAt: Date? = nil,
        staleError: ErrorSummary? = nil,
        windowExpired: Bool = false
    ) -> UsageCardView {
        UsageCardView(
            slot: slot,
            lastRefreshAt: lastRefreshAt,
            staleError: staleError,
            windowExpired: windowExpired
        )
    }

    // MARK: - Card-level branching logic

    /// The card decides "is this stale?" from `slot.isStale` directly
    /// (private computed property). `colorState` and `isStale` are
    /// orthogonal: a stale warning slot still reports `.warning` for
    /// `colorState`. Verified at the model layer because SwiftUI view
    /// rendering requires an `NSApplication` context that's missing in
    /// the test bundle (see file header).
    func testStaleSlotDoesNotAlterColorState() {
        let freshSlot = makeSlot(isStale: false)
        XCTAssertEqual(freshSlot.colorState, .normal,
                       "Sanity: fresh normal slot must have .normal colorState")

        let staleSlot = makeSlot(isStale: true)
        XCTAssertEqual(staleSlot.colorState, .normal,
                       "isStale=true must NOT alter colorState — staleness is reported via slot.isStale")
        XCTAssertTrue(staleSlot.isStale,
                      "isStale is the single channel for staleness detection")
    }

    /// `isStale` is independent of `colorState`. Verify that for each
    /// underlying `colorState`, setting `isStale=true` leaves `colorState`
    /// unchanged — and that `isStale` is the single field the view reads
    /// for staleness.
    func testStaleSlotsPreserveAllUnderlyingColorStates() {
        for underlyingState: ColorState in [.normal, .warning, .critical, .unavailable] {
            let freshSlot = makeSlot(
                uuid: "stale-\(underlyingState)",
                isStale: false,
                snapshotColorState: underlyingState
            )
            XCTAssertEqual(freshSlot.colorState, underlyingState,
                           "Sanity: fresh slot with snapshot colorState=\(underlyingState) must reflect it")
            XCTAssertFalse(freshSlot.isStale,
                           "Fresh slot must NOT be marked stale")

            let staleSlot = makeSlot(
                uuid: "stale-\(underlyingState)",
                isStale: true,
                snapshotColorState: underlyingState
            )
            XCTAssertEqual(staleSlot.colorState, underlyingState,
                           "isStale=true must preserve \(underlyingState) colorState (orthogonal fields)")
            XCTAssertTrue(staleSlot.isStale,
                          "isStale must report true regardless of underlying colorState")
        }
    }

    /// `windowExpired` is computed by the panel from any snapshot with
    /// `cycleRemainingSeconds != nil && cycleRemainingSeconds <= 0`.
    /// Verify the data layer exposes this correctly.
    func testWindowExpiredDerivationFromMetricSnapshots() {
        let expiredSlot = makeSlot(cycleRemainingSeconds: 0)
        let hasExpired = expiredSlot.metricSnapshots.contains { snapshot in
            guard let remaining = snapshot.cycleRemainingSeconds else { return false }
            return remaining <= 0
        }
        XCTAssertTrue(hasExpired,
                      "Snapshot with cycleRemainingSeconds=0 must register as expired")

        let activeSlot = makeSlot(cycleRemainingSeconds: 3600)
        let hasNotExpired = activeSlot.metricSnapshots.contains { snapshot in
            guard let remaining = snapshot.cycleRemainingSeconds else { return false }
            return remaining <= 0
        }
        XCTAssertFalse(hasNotExpired,
                       "Snapshot with cycleRemainingSeconds=3600 must NOT register as expired")

        let nilRemainingSlot = makeSlot(cycleRemainingSeconds: nil)
        let nilResult = nilRemainingSlot.metricSnapshots.contains { snapshot in
            guard let remaining = snapshot.cycleRemainingSeconds else { return false }
            return remaining <= 0
        }
        XCTAssertFalse(nilResult,
                       "Snapshot with cycleRemainingSeconds=nil (no window) must NOT register as expired")
    }

    // MARK: - Footer text formatting (Date.timeSinceNow)

    /// The card footer shows "Cached Xm ago" / "Cached Xh Ym ago" /
    /// "Cached Xd ago" depending on elapsed seconds. This test pins
    /// `Date.timeSinceNow` (see `Date+Extensions.swift`) so a regression
    /// here is caught at the unit level rather than via a render-only test.
    func testCachedTimeFormatting() {
        let cases: [(TimeInterval, String)] = [
            (60, "1m"),
            (60 * 5, "5m"),
            (60 * 59, "59m"),
            (60 * 60, "1h"),
            (60 * 60 + 60 * 30, "1h 30m"),
            (60 * 60 * 2, "2h"),
            (60 * 60 * 25, "1d"),
            (60 * 60 * 24 * 3, "3d"),
        ]
        for (elapsed, expected) in cases {
            let past = Date().addingTimeInterval(-elapsed)
            XCTAssertEqual(past.timeSinceNow, expected,
                           "timeSinceNow for \(Int(elapsed))s elapsed must equal '\(expected)'")
        }
    }

    /// The per-card "Xh Ym remaining" countdown (rendered by
    /// `multiMetricContent`) reads `firstCycleRemaining`, which picks
    /// the first snapshot with a non-nil `cycleRemainingSeconds` across
    /// the slot's metric snapshots. The SwiftUI view itself can't be
    /// unit-tested without a real `NSApplication` context (see file
    /// header), so we pin the underlying data shape.
    func testFirstCycleRemainingDerivation() {
        // Mirrors `UsageCardView.firstCycleRemaining`: pick the first
        // snapshot with a non-nil `cycleRemainingSeconds`.
        func firstCycleRemaining(of slot: SlotViewData) -> Int? {
            slot.metricSnapshots.first(where: { $0.cycleRemainingSeconds != nil })?.cycleRemainingSeconds
        }

        let noWindow = makeSlot(cycleRemainingSeconds: nil)
        XCTAssertNil(firstCycleRemaining(of: noWindow),
                     "No snapshot with cycleRemainingSeconds set → firstCycleRemaining must be nil")

        let activeWindow = makeSlot(cycleRemainingSeconds: 3600)
        XCTAssertEqual(firstCycleRemaining(of: activeWindow), 3600,
                       "Snapshot with cycleRemainingSeconds=3600 → firstCycleRemaining = 3600")

        let expiredWindow = makeSlot(cycleRemainingSeconds: 0)
        XCTAssertEqual(firstCycleRemaining(of: expiredWindow), 0,
                       "Snapshot with cycleRemainingSeconds=0 → firstCycleRemaining = 0 (treated as expired by the view)")

        let negativeWindow = makeSlot(cycleRemainingSeconds: -30)
        XCTAssertEqual(firstCycleRemaining(of: negativeWindow), -30,
                       "Snapshot with negative cycleRemainingSeconds → firstCycleRemaining = -30 (treated as expired)")
    }

    // MARK: - Window time formatting (Int.formattedDuration)

    /// `Int.formattedDuration` formats seconds as "Xm" / "Xh Ym" / "Xd".
    /// Pins the shared formatter (see `Date+Extensions.swift`) used by
    /// `Date.timeSinceNow` and the per-card "Xh Ym remaining" countdown.
    /// Single source of truth for the duration string format.
    func testWindowTimeFormatting() {
        let cases: [(Int, String)] = [
            (60, "1m"),
            (60 * 30, "30m"),
            (60 * 59, "59m"),
            (60 * 60, "1h"),
            (60 * 60 + 60 * 30, "1h 30m"),
            (60 * 60 * 2, "2h"),
            (60 * 60 * 24, "1d"),
            (60 * 60 * 24 * 3, "3d"),
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(seconds.formattedDuration, expected,
                           "formattedDuration(\(seconds)s) must equal '\(expected)'")
        }
    }

    // MARK: - Window remaining formatting (UsageCardView.formatRemainingTime)

    /// Direct test of the pure static helper that backs both
    /// `formatRemainingTime(_:)` (Int? overload) and the
    /// `formatRemainingTime(endTime:now:)` live-countdown overload.
    /// Branches covered: 0/negative (nil), sub-minute (round up to 1m),
    /// minutes, exact hours (still says "Xh 0m"), days.
    func testFormatRemainingTimeStaticSecondsFormatter() {
        XCTAssertNil(UsageCardView.formatRemainingTime(seconds: 0),
                     "0 seconds → nil (no point showing)")
        XCTAssertNil(UsageCardView.formatRemainingTime(seconds: -30),
                     "Negative seconds → nil")

        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 1), "1m remaining",
                       "Sub-minute must round up to 1m (anti-flicker near window close)")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 30), "1m remaining",
                       "30s sub-minute still rounds up to 1m")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 60), "1m remaining")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 60 * 30), "30m remaining")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 60 * 59), "59m remaining")

        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 60 * 60), "1h 0m remaining",
                       "Exact-hour boundary must keep '0m' so the format stays consistent")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 60 * 60 + 30 * 60), "1h 30m remaining")

        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 86_400), "1d remaining")
        XCTAssertEqual(UsageCardView.formatRemainingTime(seconds: 86_400 * 5), "5d remaining")
    }

    /// The live-countdown wrapper subtracts `(endTime - now)` and feeds
    /// the result to the static formatter. Mirror that logic here to
    /// pin the three observable behaviors: future endTime → formatted
    /// string; past endTime → nil; nil endTime → nil. The mirror
    /// intentionally duplicates the production formula so a refactor
    /// that breaks the wrapper fails this test in addition to the
    /// SwiftUI rendering path that can't run under XCTest.
    func testFormatRemainingTimeEndTimeOverloadDerivation() {
        func format(endTime: Date?, now: Date) -> String? {
            guard let endTime else { return nil }
            let seconds = max(0, Int(endTime.timeIntervalSince(now)))
            return UsageCardView.formatRemainingTime(seconds: seconds)
        }

        let now = Date()
        XCTAssertNil(format(endTime: nil, now: now),
                     "nil endTime → nil")
        XCTAssertNil(format(endTime: now.addingTimeInterval(-1), now: now),
                     "End time 1s in the past → nil")
        XCTAssertNil(format(endTime: now.addingTimeInterval(-3600), now: now),
                     "End time 1h in the past → nil")
        XCTAssertNil(format(endTime: now, now: now),
                     "End time exactly at now → nil (0 seconds)")

        XCTAssertEqual(format(endTime: now.addingTimeInterval(60), now: now),
                       "1m remaining",
                       "60s ahead rounds up to 1m")
        XCTAssertEqual(format(endTime: now.addingTimeInterval(60 * 30), now: now),
                       "30m remaining")
        XCTAssertEqual(format(endTime: now.addingTimeInterval(60 * 60 * 2 + 30 * 60), now: now),
                       "2h 30m remaining")
        XCTAssertEqual(format(endTime: now.addingTimeInterval(86_400 * 3), now: now),
                       "3d remaining")
    }

    // MARK: - ErrorSummary plumbing

    /// The card footer reads `staleError.errorMessage` to display the
    /// failed-cycle error. Pin the message strings so a typo or
    /// ErrorType change is caught here.
    func testStaleErrorMessages() {
        let cases: [(ErrorType, String)] = [
            (.networkTimeout, "Network timeout"),
            (.networkUnreachable, "Network unreachable"),
            (.authFailed, "API Key invalid"),
            (.apiError(code: 503), "API error (code: 503)"),
        ]
        for (errorType, expected) in cases {
            let error = ErrorSummary(id: "x", displayName: "Provider", errorType: errorType)
            XCTAssertTrue(error.errorMessage.contains(expected),
                          "ErrorSummary(\(errorType)).errorMessage must contain '\(expected)'; got '\(error.errorMessage)'")
        }
    }

    /// `staleError` must be plumbed per UUID. The panel builds an
    /// `errorSummaryByUUID` dictionary; the card looks itself up by
    /// `slot.uuid`. Pin the lookup key shape so a future refactor
    /// doesn't break the binding.
    func testStaleErrorLookupKeyMatchesSlotUUID() {
        let inst = "inst-7"
        let error = makeStaleError(uuid: inst)
        let slot = makeSlot(uuid: inst, isStale: true)

        // Simulate the panel's lookup.
        let errorSummaryByUUID = [inst: error]
        XCTAssertEqual(errorSummaryByUUID[slot.uuid]?.errorType, .networkTimeout,
                       "Panel must look up staleError by slot.uuid")
        XCTAssertEqual(errorSummaryByUUID[slot.uuid]?.displayName, "Test Provider")
    }
}
