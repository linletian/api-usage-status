import Foundation

/// Parses the OpenCode Go usage API response
/// (`GET https://opencode.ai/zen/go/v1/usage`, shipped via anomalyco/opencode
/// PR #16513).
///
/// The server is the single source of truth for the three plan windows
/// (rolling 5h, weekly, monthly): it reports each window's used `percent`
/// (integer 0–100, floored; always 100 when `status` is `rate-limited`) and
/// absolute `resetsAt` timestamp. Only plan (lite) usage is counted
/// server-side — balance top-up consumption is excluded — so the values are
/// consistent across devices, unlike the retired local-SQLite approach.
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
              let percent = (dict["percent"] as? NSNumber)?.doubleValue,
              let resetsAt = dict["resetsAt"] as? String,
              let endDate = iso8601WithFractionalSeconds.date(from: resetsAt) else {
            throw RefreshError.parsingError("OpenCode usage window '\(key)' is missing percent/resetsAt")
        }
        return ParsedWindow(
            percent: max(0, min(100, percent)),
            endTimeMs: Int64(endDate.timeIntervalSince1970 * 1000)
        )
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
