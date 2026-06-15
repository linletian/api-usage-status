import Foundation

/// Parses `opencode db` query output and computes the three usage windows.
///
/// The `opencode` CLI returns one JSON object per query (not an array) when
/// the result has aggregate columns like `SUM(...)` and `MIN(...)`. We accept
/// both shapes (`{...}` and `[{...}]`) to be lenient.
struct OpenCodeResponseParser {
    struct ParsedWindow: Equatable {
        /// Dollars spent in this window.
        let used: Double
        /// Plan upper bound in dollars.
        let limit: Double
        /// 0..100, clamped.
        let percent: Double
        /// Absolute reset time as Unix milliseconds, used by
        /// `RefreshService` to compute `cycleRemainingSeconds`. `nil` when
        /// the parser cannot determine when the window resets.
        let endTimeMs: Int64?
    }

    struct ParsedPrimary: Equatable {
        let fiveHourCost: Double
        let weeklyCost: Double
        /// First assistant message timestamp in the entire history (Unix ms).
        /// Used as the anchor for the monthly window.
        let anchorMs: Int64?
        /// Timestamp of the oldest message in the rolling 5h window, or `nil`
        /// when the window is empty.
        let fiveHourOldestMs: Int64?
    }

    struct Parsed: Equatable {
        let fiveHour: ParsedWindow
        let weekly: ParsedWindow
        let monthly: ParsedWindow
    }

    // MARK: - Public parse

    func parsePrimary(_ data: Data) throws -> ParsedPrimary {
        let json = try decodeRootObject(data, key: "primary")
        let fiveHour = (json["five_hour_cost"] as? NSNumber)?.doubleValue
            ?? (json["five_hour_cost"] as? Double)
            ?? 0
        let weekly = (json["weekly_cost"] as? NSNumber)?.doubleValue
            ?? (json["weekly_cost"] as? Double)
            ?? 0
        let anchor = (json["anchor_ms"] as? NSNumber)?.int64Value
        let oldest = (json["five_hour_oldest_ms"] as? NSNumber)?.int64Value
        return ParsedPrimary(
            fiveHourCost: fiveHour,
            weeklyCost: weekly,
            anchorMs: anchor,
            fiveHourOldestMs: oldest
        )
    }

    func parseMonthly(_ data: Data) throws -> Double {
        let json = try decodeRootObject(data, key: "monthly")
        return (json["monthly_cost"] as? NSNumber)?.doubleValue
            ?? (json["monthly_cost"] as? Double)
            ?? 0
    }

    /// End-to-end parse: combines the two query results with their
    /// respective `now` anchors into a single `Parsed` snapshot.
    func buildParsed(
        primary: ParsedPrimary,
        monthlyCost: Double,
        now: Date
    ) -> Parsed {
        let anchorDate = primary.anchorMs.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }

        let fiveHourEnd = Self.fiveHourResetDate(
            from: primary.fiveHourOldestMs,
            fallback: now
        )
        let weeklyEnd = Self.nextMondayMidnightUTC(from: now)
        let monthlyEnd = anchorDate.map { Self.anchoredMonthEnd(now: now, anchor: $0) }
            ?? now.addingTimeInterval(30 * 86400)

        return Parsed(
            fiveHour: ParsedWindow(
                used: primary.fiveHourCost,
                limit: OpenCodeGoLimits.fiveHour,
                percent: percent(primary.fiveHourCost, limit: OpenCodeGoLimits.fiveHour),
                endTimeMs: Int64(fiveHourEnd.timeIntervalSince1970 * 1000)
            ),
            weekly: ParsedWindow(
                used: primary.weeklyCost,
                limit: OpenCodeGoLimits.weekly,
                percent: percent(primary.weeklyCost, limit: OpenCodeGoLimits.weekly),
                endTimeMs: Int64(weeklyEnd.timeIntervalSince1970 * 1000)
            ),
            monthly: ParsedWindow(
                used: monthlyCost,
                limit: OpenCodeGoLimits.monthly,
                percent: percent(monthlyCost, limit: OpenCodeGoLimits.monthly),
                endTimeMs: Int64(monthlyEnd.timeIntervalSince1970 * 1000)
            )
        )
    }

    // MARK: - Window reset algorithms (pure functions)

    /// Rolling 5h window: `oldest + 5h`, or `now + 5h` when the window is empty.
    static func fiveHourResetDate(from oldestMs: Int64?, fallback now: Date) -> Date {
        guard let oldestMs else { return now.addingTimeInterval(5 * 3600) }
        let oldest = Date(timeIntervalSince1970: TimeInterval(oldestMs) / 1000)
        return oldest.addingTimeInterval(5 * 3600)
    }

    /// Weekly window: next Monday 00:00 UTC after `date`.
    static func nextMondayMidnightUTC(from date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let weekday = cal.component(.weekday, from: date) // 1=Sun..7=Sat
        let daysFromMonday = (weekday + 5) % 7           // Mon=0..Sun=6
        let startOfThisWeek = cal.date(
            byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: date)
        ) ?? date
        // The window is "this Monday .. next Monday". We report the next
        // Monday as the reset time.
        return cal.date(byAdding: .day, value: 7, to: startOfThisWeek) ?? startOfThisWeek
    }

    /// Monthly window: anchor day-of-month + 1 month (UTC). If the anchor day
    /// in the current month is in the future, the active window started last
    /// month, so the reset is one month earlier than naive arithmetic.
    static func anchoredMonthEnd(now: Date, anchor: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let anchorComps = cal.dateComponents([.day, .hour, .minute, .second], from: anchor)
        let nowYearMonth = cal.dateComponents([.year, .month], from: now)

        var candidateComps = DateComponents()
        candidateComps.year = nowYearMonth.year
        candidateComps.month = nowYearMonth.month
        candidateComps.day = anchorComps.day
        candidateComps.hour = anchorComps.hour
        candidateComps.minute = anchorComps.minute
        candidateComps.second = anchorComps.second

        var candidate = cal.date(from: candidateComps) ?? anchor
        if candidate <= now {
            candidate = cal.date(byAdding: .month, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    // MARK: - Helpers

    private func decodeRootObject(_ data: Data, key: String) throws -> [String: Any] {
        let any = try JSONSerialization.jsonObject(with: data)
        if let dict = any as? [String: Any] {
            return dict
        }
        if let array = any as? [[String: Any]], let first = array.first {
            return first
        }
        throw RefreshError.parsingError("OpenCode \(key) response is not a JSON object")
    }

    private func percent(_ used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(100, max(0, used / limit * 100))
    }
}
