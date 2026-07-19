import Foundation

/// Parses Kimi For Coding usage API responses into internal dimension identifiers.
///
/// API response structure (verified 2026-07-19 against `GET https://api.kimi.com/coding/v1/usages`,
/// the endpoint behind the Kimi Code CLI `/usage` panel):
/// ```json
/// {
///   "user": { "userId": "...", "region": "REGION_CN", "membership": { "level": "LEVEL_INTERMEDIATE" } },
///   "usage": { "limit": "100", "used": "1", "remaining": "99", "resetTime": "2026-07-26T05:20:54.627714Z" },
///   "limits": [
///     { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
///       "detail": { "limit": "100", "used": "6", "remaining": "94", "resetTime": "2026-07-19T10:20:54.627714Z" } }
///   ],
///   "parallel": { "limit": "20" },
///   "totalQuota": { "limit": "100", "remaining": "99" },
///   "subType": "TYPE_PURCHASE"
/// }
/// ```
///
/// Two windows map onto the MiniMax rawData contract with a fixed group `kimi`:
/// - `usage` (weekly subscription quota) → `kimi:weekly_percent` / `kimi:weekly_status` /
///   `kimi:weekly_remaining` / `kimi:weekly_percent:end_time`
/// - `limits[]` (rolling rate window, 300 minutes) → `kimi` / `kimi:status` /
///   `kimi:remaining` / `kimi:end_time`
///
/// All quota numbers arrive as JSON strings ("100"). Usage percent is derived as
/// `used / limit * 100`, clamped to 0...100. `resetTime` is ISO 8601 with fractional
/// seconds and is published as epoch milliseconds under the standard `<key>:end_time`
/// keys so `RefreshService` populates `cycleEndTime` like any other provider.
///
/// Strictness follows `CopilotResponseParser`: when a window block is present but its
/// `limit` / `used` fields are missing or non-numeric, the parser throws
/// `RefreshError.parsingError` instead of inventing a percent (which could trigger
/// false threshold alerts). When a block is absent entirely the window reports 0%
/// (and the weekly window reports `weekly_status = "0"`, i.e. unlimited), matching
/// `MiniMaxResponseParser`'s "no quota tracked" semantics.
struct KimiResponseParser {
    /// Fixed group identifier — Kimi For Coding exposes exactly one quota group
    /// (unlike MiniMax's per-model groups), so both windows share it.
    static let groupKey = "kimi"

    func parse(_ data: Data) throws -> SupplierResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.parsingError("Invalid JSON from Kimi API")
        }

        var rawData: [String: String] = [:]
        let group = Self.groupKey

        // --- Rolling rate window (limits[]): the 5h (300-minute) entry ---
        let limits = json["limits"] as? [[String: Any]] ?? []
        let rollingEntry = limits.first(where: { entry in
            guard let window = entry["window"] as? [String: Any] else { return false }
            return tolerantInt(window["duration"]) == 300
                && (window["timeUnit"] as? String) == "TIME_UNIT_MINUTE"
        }) ?? limits.first

        if let detail = rollingEntry?["detail"] as? [String: Any] {
            let limit = try numericValue(detail, key: "limit")
            let used = try numericValue(detail, key: "used")
            let usagePercent = Self.usagePercent(used: used, limit: limit)
            rawData[group] = formatPercent(usagePercent)
            rawData["\(group):status"] = "1"
            rawData["\(group):remaining"] = String(format: "%.1f", max(0, 100.0 - usagePercent))
            rawData["\(group):end_time"] = String(Self.parseISO8601ToMs(detail["resetTime"] as? String) ?? 0)
        } else {
            // No rolling window tracked for this account — report 0% rather
            // than failing the whole refresh.
            rawData[group] = formatPercent(0)
            rawData["\(group):status"] = "0"
            rawData["\(group):remaining"] = "100.0"
            rawData["\(group):end_time"] = "0"
        }

        // --- Weekly subscription quota (usage) ---
        if let usage = json["usage"] as? [String: Any] {
            let limit = try numericValue(usage, key: "limit")
            let used = try numericValue(usage, key: "used")
            let usagePercent = Self.usagePercent(used: used, limit: limit)
            rawData["\(group):weekly_percent"] = formatPercent(usagePercent)
            // limit <= 0 with a present block means the plan does not enforce
            // a weekly cap — surface as unlimited (flowing glow bar).
            rawData["\(group):weekly_status"] = limit > 0 ? "1" : "0"
            rawData["\(group):weekly_remaining"] = String(format: "%.1f", max(0, 100.0 - usagePercent))
            rawData["\(group):weekly_percent:end_time"] = String(Self.parseISO8601ToMs(usage["resetTime"] as? String) ?? 0)
        } else {
            // No subscription quota block — treat as unlimited.
            rawData["\(group):weekly_percent"] = formatPercent(0)
            rawData["\(group):weekly_status"] = "0"
            rawData["\(group):weekly_remaining"] = "100.0"
            rawData["\(group):weekly_percent:end_time"] = "0"
        }

        // --- Informational fields (debug / future detail panel) ---
        if let user = json["user"] as? [String: Any],
           let membership = user["membership"] as? [String: Any],
           let level = membership["level"] as? String {
            rawData["\(group):membership"] = level
        }
        if let parallel = json["parallel"] as? [String: Any],
           let limit = parallel["limit"] {
            rawData["\(group):parallel_limit"] = "\(limit)"
        }

        return SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)
    }

    /// Usage percent from a `used` / `limit` pair. A non-positive limit means
    /// the window is not enforced — report 0% usage.
    private static func usagePercent(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return max(0, min(100, used / limit * 100.0))
    }

    /// Kimi returns quota numbers as JSON strings; tolerate numeric types too.
    /// Throws (never silently defaults) when the key is missing or non-numeric,
    /// so a malformed block fails the refresh instead of producing a fake percent.
    private func numericValue(_ entry: [String: Any], key: String) throws -> Double {
        if let d = entry[key] as? Double { return d }
        if let i = entry[key] as? Int { return Double(i) }
        if let n = entry[key] as? NSNumber { return n.doubleValue }
        if let s = entry[key] as? String, let d = Double(s.trimmed) { return d }
        if let value = entry[key] {
            throw RefreshError.parsingError(
                "Non-numeric value for \(key) in Kimi response: \(value) (type: \(type(of: value)))"
            )
        }
        throw RefreshError.parsingError("Missing field in Kimi response: \(key)")
    }

    private func tolerantInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func formatPercent(_ value: Double) -> String {
        let clamped = min(100.0, max(0.0, value))
        return String(format: "%.1f", clamped)
    }

    /// Parse Kimi's `resetTime` (ISO 8601, observed with 6-digit fractional
    /// seconds, e.g. "2026-07-26T05:20:54.627714Z") into epoch milliseconds.
    /// Returns `nil` for missing/unparseable input — callers write `0`, which
    /// `RefreshService` treats as "no countdown available" rather than an error.
    static func parseISO8601ToMs(_ string: String?) -> Int64? {
        guard let string, !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
