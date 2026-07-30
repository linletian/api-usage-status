import Foundation

/// Parses GitHub Copilot Internal API responses into the `premium_interactions` dimension.
///
/// API response structure (current format, sampled 2026-07-30):
/// ```json
/// {
///   "copilot_plan": "individual_pro",
///   "quota_reset_date_utc": "2026-08-01T00:00:00.000Z",
///   "quota_snapshots": {
///     "premium_interactions": {
///       "entitlement": 7000,
///       "percent_remaining": 0.0,
///       "remaining": -1055,
///       "unlimited": false,
///       "overage_count": 1000,
///       "overage_permitted": false,
///       "credits_used": 8054,
///       "quota_remaining": -1054.2
///     }
///   }
/// }
/// ```
///
/// As of 2026-07-30 GitHub stopped flipping `overage_permitted` to `true`
/// when the user is over-budget, and stopped preserving negative precision
/// in `percent_remaining`. Both are now unreliable as overage signals —
/// see `docs/copilot-overage-stuck-at-100-percent.md` for the full
/// investigation. Over-budget is detected via `remaining < 0` /
/// `quota_remaining < 0` / `credits_used > entitlement`, with `credits_used`
/// preferred for the percentage calculation when present.
///
/// Core numeric fields (`entitlement` / `remaining` / `percent_remaining`)
/// throw `RefreshError.parsingError` on missing or non-numeric values. This
/// is intentional: silently defaulting to 0 would make `usagePercent = 100`,
/// triggering false 100% critical alerts when the API response changes shape.
/// Optional fields like `overage_count`, `overage_permitted`, `credits_used`,
/// `quota_remaining` degrade gracefully to defaults.
///
/// `unlimited == true` plans (Pro+/Business unlimited tiers) report a usage
/// percent of 0 — aligned with `MiniMaxResponseParser`'s handling of an inactive
/// quota window (`status != 1`). The `:unlimited` side key preserves the raw
/// state so the rendering layer can show a distinct visual if desired.
struct CopilotResponseParser {
    private static let dimensionKey = "premium_interactions"

    func parse(_ data: Data) throws -> SupplierResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.parsingError("Invalid JSON from Copilot API")
        }

        let plan = json["copilot_plan"] as? String ?? "unknown"
        let resetDate = json["quota_reset_date_utc"] as? String ?? ""

        guard let snapshots = json["quota_snapshots"] as? [String: Any],
              let pi = snapshots[Self.dimensionKey] as? [String: Any] else {
            throw RefreshError.parsingError("Missing quota_snapshots.premium_interactions")
        }

        let unlimited = pi["unlimited"] as? Bool ?? false
        let entitlement = try numericValue(pi, key: "entitlement")
        let remaining = try numericValue(pi, key: "remaining")
        let percentRemaining = try numericValue(pi, key: "percent_remaining")
        // `overage_count` and `overage_permitted` are kept for backward compat
        // with the pre-2026-07 API shape. As of 2026-07-30 GitHub stopped
        // flipping `overage_permitted` to true when the user is over-budget,
        // so it can no longer be trusted as the sole overage signal — see
        // `isOverage` below, which also checks `remaining < 0` and
        // `credits_used > entitlement` from the current contract.
        let overageCount = (try? numericValue(pi, key: "overage_count")) ?? 0
        let overagePermitted = pi["overage_permitted"] as? Bool ?? false
        // Authoritative "total used" field added in the 2026-07 API shape.
        // Absent on older responses; defaults to 0 and the legacy formula
        // takes over.
        let creditsUsed = (try? numericValue(pi, key: "credits_used")) ?? 0
        let quotaRemaining = (try? numericValue(pi, key: "quota_remaining")) ?? 0

        let usagePercent: Double = {
            if unlimited { return 0 }
            // Over-budget signal. The current API shape encodes overage via
            // negative `remaining` / `quota_remaining` (with `percent_remaining`
            // truncated to 0 so we can't trust it alone), plus `credits_used`
            // exceeding `entitlement`. The legacy `overage_permitted` flag is
            // retained as a fallback so older API responses keep working.
            let isNewOverage = remaining < 0 || quotaRemaining < 0 || creditsUsed > entitlement
            let isLegacyOverage = overagePermitted && overageCount > 0
            guard isNewOverage || isLegacyOverage else {
                return max(0, min(100, 100.0 - percentRemaining))
            }
            // Prefer `credits_used` when the API supplies it — it's the
            // authoritative "total used" count. Otherwise fall back: in the
            // new API shape `remaining < 0` already reflects overage, so
            // `entitlement - remaining` is the true total; in the legacy
            // shape `remaining` was clamped to 0 and overage lived in
            // `overageCount`, so the two are additive.
            if creditsUsed > 0, entitlement > 0 {
                return creditsUsed / entitlement * 100
            }
            if entitlement > 0 {
                let totalUsage = remaining < 0
                    ? entitlement - remaining
                    : entitlement + overageCount
                return max(0, totalUsage / entitlement * 100)
            }
            return 0
        }()

        var rawData: [String: String] = [:]
        rawData[Self.dimensionKey] = formatPercent(usagePercent)
        rawData["\(Self.dimensionKey):unlimited"] = unlimited ? "true" : "false"
        rawData["\(Self.dimensionKey):entitlement"] = String(Int(entitlement))
        rawData["\(Self.dimensionKey):remaining"] = String(Int(remaining))
        rawData["\(Self.dimensionKey):percent_remaining"] = String(format: "%.1f", percentRemaining)
        // Publish the reset instant under the standard `end_time` ms key
        // so `RefreshService` can populate `cycleEndTime` for the live
        // "Xh Ym remaining" countdown. When `quota_reset_date_utc` is
        // missing or unparseable, fall back to a computed next-monthly-reset
        // timestamp — Copilot quotas always reset on a monthly cycle.
        let endTimeMs: Int64
        if let parsed = Self.parseISO8601ToMs(resetDate), parsed > 0 {
            endTimeMs = parsed
        } else {
            endTimeMs = Self.nextMonthlyResetMs()
        }
        rawData["\(Self.dimensionKey):end_time"] = String(endTimeMs)
        rawData["\(Self.dimensionKey):reset_date"] = resetDate
        rawData["\(Self.dimensionKey):plan"] = plan
        rawData["\(Self.dimensionKey):overage_count"] = String(Int(overageCount))
        rawData["\(Self.dimensionKey):overage_permitted"] = overagePermitted ? "true" : "false"
        rawData["\(Self.dimensionKey):credits_used"] = String(Int(creditsUsed))
        rawData["\(Self.dimensionKey):quota_remaining"] = String(format: "%.1f", quotaRemaining)

        return SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)
    }

    private func numericValue(_ entry: [String: Any], key: String) throws -> Double {
        if let d = entry[key] as? Double { return d }
        if let i = entry[key] as? Int { return Double(i) }
        if let n = entry[key] as? NSNumber { return n.doubleValue }
        if let value = entry[key] {
            throw RefreshError.parsingError(
                "Non-numeric value for \(key) in Copilot response: \(value) (type: \(type(of: value)))"
            )
        }
        throw RefreshError.parsingError("Missing field in Copilot response: \(key)")
    }

    private func formatPercent(_ value: Double) -> String {
        let clamped = max(0.0, value)
        return String(format: "%.1f", clamped)
    }

    /// Parse Copilot's `quota_reset_date_utc` (ISO 8601 with trailing `Z`)
    /// into epoch milliseconds. Returns `nil` for unparseable input —
    /// callers must treat that as "no countdown available" rather than
    /// throwing, since this is not a numeric field that gates critical UI
    /// alerts.
    static func parseISO8601ToMs(_ string: String) -> Int64? {
        guard !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        // Try without fractional seconds first (canonical "Z" format),
        // then with fractional seconds (e.g. "2026-07-01T00:00:00.000Z").
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        // Fallback: date-only (e.g. "2026-07-01") — treat as UTC midnight.
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        if let date = dateOnly.date(from: string) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    /// Compute the first day of next month at 00:00:00 UTC as epoch
    /// milliseconds. Used as a fallback when `quota_reset_date_utc` is
    /// missing or unparseable — Copilot quotas always reset on a monthly
    /// cycle, so this provides a best-effort countdown until the next
    /// real `quota_reset_date_utc` arrives from the API.
    static func nextMonthlyResetMs() -> Int64 {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        guard let nextMonth = utcCalendar.date(byAdding: .month, value: 1, to: now) else {
            return 0
        }
        var components = utcCalendar.dateComponents([.year, .month], from: nextMonth)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let firstOfNextMonth = utcCalendar.date(from: components) else {
            return 0
        }
        return Int64(firstOfNextMonth.timeIntervalSince1970 * 1000)
    }
}
