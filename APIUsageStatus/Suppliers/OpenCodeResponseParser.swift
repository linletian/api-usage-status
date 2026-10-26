import Foundation

/// Parses the OpenCode Go usage API response
/// (`GET https://opencode.ai/zen/go/v1/usage`, shipped via anomalyco/opencode
/// PR #16513).
///
/// The server is the single source of truth for the three plan windows
/// (rolling 5h, weekly, monthly): it reports each window's used `percent`
/// (integer 0–100, floored) and absolute `resetsAt` timestamp. The parser
/// forces percent to 100 when `status` is `rate-limited` — the server-side
/// contract (`Subscription.analyze*Usage`) couples the two, and enforcing it
/// here keeps schema drift from rendering a partial bar on an exhausted
/// window. Only plan (lite) usage is counted server-side — balance top-up
/// consumption is excluded — so the values are consistent across devices,
/// unlike the retired local-SQLite approach.
///
/// Response shape:
///
///     {"usage":{
///       "rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-02T19:44:30.306Z"},
///       "weekly":{...},
///       "monthly":{...}}}
struct OpenCodeResponseParser {
    struct ParsedWindow: Equatable {
        /// 0..100 used percent reported by the server.
        let percent: Double
        /// Absolute reset time as Unix milliseconds, used by
        /// `RefreshService` to compute `cycleEndTime` (and derive
        /// `cycleRemainingSeconds` from it).
        let endTimeMs: Int64
    }

    struct Parsed: Equatable {
        let fiveHour: ParsedWindow
        let weekly: ParsedWindow
        let monthly: ParsedWindow
    }

    // MARK: - Public parse

    func parse(_ data: Data) throws -> Parsed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else {
            throw RefreshError.parsingError("OpenCode usage response is not a JSON object with a 'usage' key")
        }
        return Parsed(
            fiveHour: try Self.parseWindow(usage["rolling"], key: "rolling"),
            weekly: try Self.parseWindow(usage["weekly"], key: "weekly"),
            monthly: try Self.parseWindow(usage["monthly"], key: "monthly")
        )
    }

    // MARK: - Window parsing

    private static func parseWindow(_ any: Any?, key: String) throws -> ParsedWindow {
        guard let dict = any as? [String: Any],
              let rawPercent = (dict["percent"] as? NSNumber)?.doubleValue,
              let resetsAt = dict["resetsAt"] as? String,
              let endDate = parseResetsAt(resetsAt) else {
            throw RefreshError.parsingError("OpenCode usage window '\(key)' is missing percent/resetsAt")
        }
        // The server emits percent=100 together with `rate-limited`
        // (`Subscription.analyze*Usage`); enforce it here so schema drift
        // can never render a partially-used bar on an exhausted window.
        let isRateLimited = dict["status"] as? String == "rate-limited"
        return ParsedWindow(
            percent: isRateLimited ? 100 : max(0, min(100, rawPercent)),
            endTimeMs: Int64(endDate.timeIntervalSince1970 * 1000)
        )
    }

    /// `resetsAt` is documented as ISO8601 with milliseconds, but accept a
    /// bare second-resolution timestamp too — a missing fraction is metadata
    /// drift, not worth failing all three windows over.
    private static func parseResetsAt(_ string: String) -> Date? {
        iso8601WithFractionalSeconds.date(from: string)
            ?? iso8601.date(from: string)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
