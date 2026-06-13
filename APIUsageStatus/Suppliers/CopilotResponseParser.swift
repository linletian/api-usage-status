import Foundation

/// Parses GitHub Copilot Internal API responses into the `premium_interactions` dimension.
///
/// API response structure (current format):
/// ```json
/// {
///   "copilot_plan": "pro",
///   "quota_reset_date_utc": "2026-07-01T00:00:00Z",
///   "quota_snapshots": {
///     "premium_interactions": {
///       "entitlement": 300,
///       "percent_remaining": 73.33,
///       "remaining": 220,
///       "unlimited": false,
///       "overage_count": 0,
///       "overage_permitted": false
///     }
///   }
/// }
/// ```
///
/// Core numeric fields (`entitlement` / `remaining` / `percent_remaining`)
/// throw `RefreshError.parsingError` on missing or non-numeric values. This
/// is intentional: silently defaulting to 0 would make `usagePercent = 100`,
/// triggering false 100% critical alerts when the API response changes shape.
/// Optional fields like `overage_count` (reserved for future use) degrade
/// gracefully to 0.
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
        // overage_count is optional (reserved for future overage warnings);
        // missing is fine and defaults to 0.
        let overageCount = (try? numericValue(pi, key: "overage_count")) ?? 0
        let overagePermitted = pi["overage_permitted"] as? Bool ?? false

        let usagePercent: Double = unlimited
            ? 0
            : max(0, min(100, 100.0 - percentRemaining))

        var rawData: [String: String] = [:]
        rawData[Self.dimensionKey] = formatPercent(usagePercent)
        rawData["\(Self.dimensionKey):unlimited"] = unlimited ? "true" : "false"
        rawData["\(Self.dimensionKey):entitlement"] = String(Int(entitlement))
        rawData["\(Self.dimensionKey):remaining"] = String(Int(remaining))
        rawData["\(Self.dimensionKey):percent_remaining"] = String(format: "%.1f", percentRemaining)
        rawData["\(Self.dimensionKey):reset_date"] = resetDate
        rawData["\(Self.dimensionKey):plan"] = plan
        rawData["\(Self.dimensionKey):overage_count"] = String(Int(overageCount))
        rawData["\(Self.dimensionKey):overage_permitted"] = overagePermitted ? "true" : "false"

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
        let clamped = min(100.0, max(0.0, value))
        return String(format: "%.1f", clamped)
    }
}
