import XCTest
@testable import APIUsageStatus

// MARK: - PeakPeriodTests
//
// DeepSeek officially announced that API usage is billed differently during
// peak and off-peak hours. Peak windows (in Beijing Time, UTC+8):
//   • 09:00 ≤ t < 12:00
//   • 14:00 ≤ t < 18:00
// Off-peak is everything else.
//
// These tests pin `PeakSchedule.isPeak(at:calendar:)` against the BJT
// boundaries and verify that a non-BJT calendar (UTC) sees the same BJT
// instants classified correctly — which proves the BJT→local conversion
// works without any explicit offset math.

final class PeakPeriodTests: XCTestCase {

    /// Helper: build a `Date` from BJT components. Internally converts to
    /// the corresponding UTC instant (since `Date` is timezone-free) so
    /// `isPeak(at:calendar: bjt)` and `isPeak(at: Date, calendar: utc)`
    /// agree on the same instant.
    private func dateAtBJTHourMinute(
        year: Int = 2026,
        month: Int = 7,
        day: Int = 1,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var bjt = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 28800)!
        var bjtCal = Calendar(identifier: .gregorian)
        bjtCal.timeZone = bjt
        var components = DateComponents(
            calendar: bjtCal,
            timeZone: bjt,
            year: year, month: month, day: day,
            hour: hour, minute: minute
        )
        // BJT calendar uses hour values 0-23 — for a clean API we keep
        // the same convention here.
        return bjtCal.date(from: components)!
    }

    private var bjtCalendar: Calendar {
        PeakSchedule.bjtCalendar
    }

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - BJT-direct (peak window truth table)

    func testPeakMidFirstWindow() {
        // 09:30 BJT — well inside peak
        let now = dateAtBJTHourMinute(hour: 9, minute: 30)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .peak)
    }

    func testPeakStartEdge() {
        // 09:00 BJT — first minute of peak
        let now = dateAtBJTHourMinute(hour: 9, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .peak)
    }

    func testPeakEndEdgeExclusive() {
        // 12:00 BJT — half-open interval: end is off-peak
        let now = dateAtBJTHourMinute(hour: 12, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testPeakJustBeforeLunch() {
        // 11:59 BJT — last minute of first peak window
        let now = dateAtBJTHourMinute(hour: 11, minute: 59)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .peak)
    }

    func testOffPeakLunch() {
        // 13:00 BJT — in the off-peak lunch window
        let now = dateAtBJTHourMinute(hour: 13, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testPeakStartOfSecondWindow() {
        // 14:00 BJT — second peak window begins
        let now = dateAtBJTHourMinute(hour: 14, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .peak)
    }

    func testPeakJustBeforeEvening() {
        // 17:59 BJT — last minute of second peak window
        let now = dateAtBJTHourMinute(hour: 17, minute: 59)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .peak)
    }

    func testOffPeakEveningStart() {
        // 18:00 BJT — second peak window ends, evening off-peak begins
        let now = dateAtBJTHourMinute(hour: 18, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testOffPeakLateEvening() {
        // 23:30 BJT — late evening, off-peak
        let now = dateAtBJTHourMinute(hour: 23, minute: 30)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testOffPeakLateNight() {
        // 02:00 BJT — early morning, off-peak
        let now = dateAtBJTHourMinute(hour: 2, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testOffPeakJustBeforeMorning() {
        // 08:59 BJT — last minute before first peak window
        let now = dateAtBJTHourMinute(hour: 8, minute: 59)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    func testOffPeakJustBeforeLunch() {
        // 13:59 BJT — last minute before second peak window
        let now = dateAtBJTHourMinute(hour: 13, minute: 59)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: bjtCalendar), .offPeak)
    }

    // MARK: - Round-trip: same instant, different calendars
    //
    // The same `Date` instant can classify differently depending on which
    // calendar extracts the hour — because BJT 09:30 is UTC 01:30 — but
    // the production `isPeak(at:)` overload ALWAYS asks the BJT calendar,
    // so the user gets the correct peak/off-peak answer regardless of
    // their machine's local timezone. These tests pin both halves of that
    // contract.
    //
    // (Removed: `testBJTCalendarReportsPeak` — it duplicated the assertion
    // in `testPeakMidFirstWindow` (both pinned 09:30 BJT → .peak against
    // the BJT calendar) without testing anything new. The UTC-side test
    // below is the substantive pairing for the production-overload test.)

    func testUTCCalendarReadsSameInstantAsOffPeak() {
        // Same `Date` as above, but read through the UTC calendar the
        // wall-clock hour becomes 01:30 — which falls outside BJT peak
        // windows. This demonstrates that the *caller's calendar choice
        // matters*; the production overload below never makes this
        // mistake because it always uses BJT.
        let now = dateAtBJTHourMinute(hour: 9, minute: 30)
        XCTAssertEqual(PeakSchedule.isPeak(at: now, calendar: utcCalendar), .offPeak)
    }

    func testProductionOverloadIgnoresLocalTimezone() {
        // Construct an instant at BJT 09:30 (peak) but run the no-arg
        // production overload — it must always ask the BJT calendar and
        // return `.peak`, regardless of the machine's timezone.
        let now = dateAtBJTHourMinute(hour: 9, minute: 30)
        XCTAssertEqual(PeakSchedule.isPeak(at: now), .peak)

        // And an instant at BJT 13:00 (lunch, off-peak) must come back
        // off-peak even though a Western Hemisphere user might see
        // 00:00 or 05:00 on their wall clock.
        let lunch = dateAtBJTHourMinute(hour: 13, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: lunch), .offPeak)

        // And the afternoon peak start must come back peak.
        let afternoonPeak = dateAtBJTHourMinute(hour: 14, minute: 0)
        XCTAssertEqual(PeakSchedule.isPeak(at: afternoonPeak), .peak)
    }

    // MARK: - Label sanity

    func testLabelsAreEnglish() {
        XCTAssertEqual(PeakSchedule.label(for: .peak), "Peak")
        XCTAssertEqual(PeakSchedule.label(for: .offPeak), "Off-Peak")
    }
}