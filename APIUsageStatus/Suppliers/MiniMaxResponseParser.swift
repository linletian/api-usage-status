import Foundation

/// Parses MiniMax token plan API responses into internal dimension identifiers.
///
/// API response structure (current format):
/// ```json
/// {
///   "model_remains": [
///     {
///       "model_name": "general",
///       "current_interval_status": 1,
///       "current_interval_remaining_percent": 28,
///       "start_time": 1781247600000,
///       "end_time": 1781265600000,
///       "remains_time": 173501,
///       "current_weekly_status": 3,
///       "current_weekly_remaining_percent": 100,
///       "weekly_start_time": 1780848000000,
///       "weekly_end_time": 1781452800000,
///       "weekly_remains_time": 187373501
///     }
///   ],
///   "base_resp": { "status_code": 0, "status_msg": "success" }
/// }
/// ```
///
/// `current_interval_status` indicates whether the model's 5h interval quota is
/// currently active (`1` = active). Other observed values (e.g. `3`) mean the
/// quota is not in effect for this window; we report 0% usage in that case.
/// The 5h usage percent is derived as `100 - current_interval_remaining_percent`.
///
/// Each `model_name` entry is treated as an independent dimension. Users can
/// configure monitoring for any model independently.
struct MiniMaxResponseParser {
    /// Parses raw JSON data into a SupplierResponse.
    /// Each model entry becomes a separate rawData entry with the model_name as key.
    /// - Parameter data: Raw data from the MiniMax API
    /// - Returns: SupplierResponse with model-name-keyed values
    func parse(_ data: Data) throws -> SupplierResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.parsingError("Invalid JSON from MiniMax API")
        }

        // Check base_resp for API-level errors
        if let baseResp = json["base_resp"] as? [String: Any],
           let statusCode = baseResp["status_code"] as? Int {
            if statusCode != 0 {
                let statusMsg = baseResp["status_msg"] as? String ?? "Unknown error"
                // Auth failures map to HTTP 401
                if statusCode == 1004 || statusCode == 1003 {
                    throw RefreshError.httpError(statusCode: 401)
                }
                throw RefreshError.parsingError("API error (\(statusCode)): \(statusMsg)")
            }
        }

        guard let modelRemains = json["model_remains"] as? [[String: Any]] else {
            throw RefreshError.parsingError("Missing or invalid model_remains")
        }

        var rawData: [String: String] = [:]

        for entry in modelRemains {
            guard let modelName = entry["model_name"] as? String else {
                continue
            }

            let remainingPercent = numericValue(entry, key: "current_interval_remaining_percent")
            let intervalStatus = entry["current_interval_status"] as? Int ?? 0
            let weeklyRemainingPercent = numericValue(entry, key: "current_weekly_remaining_percent")
            let weeklyStatus = entry["current_weekly_status"] as? Int ?? 0

            // Trust the percent data when present, regardless of status.
            // status != 1 was previously treated as "window not in effect"
            // and reported 0%, but the API also returns status != 1 when
            // the 5h window is fully consumed (remaining_percent = 0) —
            // that should display as 100%, not 0%. Only fall back to 0
            // when the percent field is entirely absent, which is the
            // genuine "no quota tracked" case (user not on a 5h plan).
            let usagePercent: Double
            if entry["current_interval_remaining_percent"] != nil {
                usagePercent = max(0, min(100, 100.0 - remainingPercent))
            } else {
                usagePercent = 0
            }
            rawData[modelName] = formatPercent(usagePercent)
            rawData["\(modelName):status"] = String(intervalStatus)
            rawData["\(modelName):remaining"] = String(format: "%.1f", remainingPercent)

            // Same trust-the-data semantics as the 5h usage above.
            // status != 1 with a present remaining_percent means the
            // weekly window is fully consumed (or otherwise out of
            // normal tracking state) and should display the actual
            // percent, not 0%.
            let weeklyUsagePercent: Double
            if entry["current_weekly_remaining_percent"] != nil {
                weeklyUsagePercent = max(0, min(100, 100.0 - weeklyRemainingPercent))
            } else {
                weeklyUsagePercent = 0
            }
            rawData["\(modelName):weekly_status"] = String(weeklyStatus)
            rawData["\(modelName):weekly_remaining"] = String(format: "%.1f", weeklyRemainingPercent)
            rawData["\(modelName):weekly_percent"] = formatPercent(weeklyUsagePercent)

            // Store interval end time (ms) so callers can compute remaining days
            let endTime = entry["end_time"] as? Int64 ?? 0
            rawData["\(modelName):end_time"] = String(endTime)
        }

        let modelNames = modelRemains.compactMap { $0["model_name"] as? String }
        rawData["_model_names"] = modelNames.joined(separator: ",")

        return SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)
    }

    private func numericValue(_ entry: [String: Any], key: String) -> Double {
        if let d = entry[key] as? Double { return d }
        if let i = entry[key] as? Int { return Double(i) }
        if let n = entry[key] as? NSNumber { return n.doubleValue }
        return 0
    }

    private func formatPercent(_ value: Double) -> String {
        let clamped = min(100.0, max(0.0, value))
        return String(format: "%.1f", clamped)
    }
}
