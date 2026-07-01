import Foundation

// MARK: - PeakPeriod
//
// DeepSeek officially announced (via direct email, 2026/06) that API usage is
// billed differently during "peak" and "off-peak" hours. The peak windows are
// fixed in Beijing Time (UTC+8):
//
//   • 09:00–12:00 BJT
//   • 14:00–18:00 BJT
//
// This app does NOT compute per-token prices — it only labels the current
// moment as peak or off-peak so the user can see at a glance whether their
// recent requests are being billed at the higher rate.
//
// `PeakSchedule.isPeak(at:)` is the single source of truth used by both the
// menu bar renderer (NSStatusItem image) and the SwiftUI badge in the popup.
// The decision is stateless — callers invoke it on demand.
//
// **Maintenance contract** — when DeepSeek adjusts the pricing windows,
// update:
//   1. `PeakSchedule.peakWindows` below
//   2. `PeakSchedule.policyVersion` (the version tag the docs/UI reference)
//   3. `docs/provider-interfaces/deepseek.md` §11
//   4. `README.md` / `README_zh-CN.md` 中对 `policyVersion` 的引用
// The four-place edit ensures the on-screen label, source of truth, and user
// docs never drift apart. `policyVersion` is `2026-06` for the current rules.

enum PeakPeriod {
    case peak
    case offPeak
}

// MARK: - PeakSchedule

/// Read-only accessor for the current peak/off-peak classification.
///
/// Time zones: windows are defined in Beijing Time. Rather than converting
/// peak windows to the user's local timezone (which would require knowing
/// the offset at a specific instant — error-prone around DST transitions),
/// we read the BJT hour and minute directly from the supplied `Date`. This
/// sidesteps every timezone-offset edge case.
enum PeakSchedule {

    /// BJT — Beijing Standard Time, no DST. Falls back to a fixed UTC+8
    /// offset if the identifier is missing on this platform (paranoia; macOS
    /// always has `Asia/Shanghai`).
    private static let bjt: TimeZone = TimeZone(identifier: "Asia/Shanghai")
        ?? TimeZone(secondsFromGMT: 28800)!

    /// Calendar pinned to BJT, used only to extract the BJT hour/minute
    /// from an arbitrary `Date`. Cached as a `static let` (Calendar is a
    /// value type — safe to share). Exposed publicly so tests can inject it
    /// into the testable `isPeak(at:calendar:)` overload below.
    static let bjtCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = bjt
        return c
    }()

    /// Peak windows expressed in minutes-of-day (BJT):
    ///   [540, 720)  →  09:00 ≤ t < 12:00
    ///   [840, 1080) →  14:00 ≤ t < 18:00
    /// Note: half-open `Range` so the end minute is excluded (12:00 itself
    /// is off-peak; 09:00 is peak).
    private static let peakWindows: [Range<Int>] = [540..<720, 840..<1080]

    /// Tag for the currently-encoded DeepSeek policy. Bumped whenever the
    /// peak-window tuple above changes, so docs (`docs/provider-interfaces/
    /// deepseek.md` §11), UI strings, and release notes can cite a stable
    /// identifier instead of chasing the schedule itself.
    /// - "2026-06" — initial launch: 09:00–12:00 / 14:00–18:00 BJT.
    static let policyVersion = "2026-06"

    /// Production entry point — uses the system-supplied BJT calendar.
    /// 60-second cadence on the caller side is acceptable; the menu bar
    /// ticker and the SwiftUI `TimelineView(.periodic(by: 60))` both redraw
    /// at this granularity, so the badge / overlay can be up to 60 s late
    /// at the boundary — fine for a hint.
    static func isPeak(at now: Date = Date()) -> PeakPeriod {
        isPeak(at: now, calendar: bjtCalendar)
    }

    /// Testable overload — caller supplies the calendar.
    static func isPeak(at now: Date, calendar: Calendar) -> PeakPeriod {
        let total = calendar.component(.hour, from: now) * 60
                  + calendar.component(.minute, from: now)
        return peakWindows.contains(where: { $0.contains(total) }) ? .peak : .offPeak
    }

    /// English label used by the popup badge.
    static func label(for period: PeakPeriod) -> String {
        switch period {
        case .peak:    return "Peak"
        case .offPeak: return "Off-Peak"
        }
    }
}