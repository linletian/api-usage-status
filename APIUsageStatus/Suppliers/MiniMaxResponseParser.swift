import Foundation

/// Parses MiniMax token plan API responses into internal dimension identifiers.
///
/// API response structure:
/// ```json
/// {
///   "model_remains": [
///     {
///       "model_name": "MiniMax-M2.7",
///       "current_interval_total_count": 600,
///       "current_interval_usage_count": 57,
///       "start_time": 1779174000000,
///       "end_time": 1779192000000,
///       "remains_time": 5024998,
///       "current_weekly_total_count": 0,
///       "current_weekly_usage_count": 0,
///       "weekly_start_time": 1779033600000,
///       "weekly_end_time": 1779638400000,
///       "weekly_remains_time": 451424998
///     },
///     ...
///   ],
///   "base_resp": { "status_code": 0, "status_msg": "success" }
/// }
/// ```
///
/// Each `model_name` entry is treated as an independent dimension.
/// Users can configure monitoring for any model independently.
///
/// For quota-style display, percentage is calculated as:
/// `current_interval_usage_count / current_interval_total_count * 100`
///
/// If `current_interval_total_count == 0`, the model has no quota limit
/// and should not display a percentage (or display N/A).
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

            let totalCount = entry["current_interval_total_count"] as? Int ?? 0
            let usageCount = entry["current_interval_usage_count"] as? Int ?? 0

            // Calculate percentage if quota exists
            if totalCount > 0 {
                let percent = Double(usageCount) / Double(totalCount) * 100.0
                rawData[modelName] = formatPercent(percent)
                rawData["\(modelName):total"] = String(totalCount)
                rawData["\(modelName):used"] = String(usageCount)
            } else {
                // No quota limit — store with special marker
                rawData[modelName] = "NO_LIMIT"
                rawData["\(modelName):total"] = "0"
                rawData["\(modelName):used"] = String(usageCount)
            }

            // Weekly quota data
            let weeklyTotal = entry["current_weekly_total_count"] as? Int ?? 0
            let weeklyUsed = entry["current_weekly_usage_count"] as? Int ?? 0
            rawData["\(modelName):weekly_total"] = String(weeklyTotal)
            rawData["\(modelName):weekly_used"] = String(weeklyUsed)

            if weeklyTotal > 0 {
                let weeklyPercent = Double(weeklyUsed) / Double(weeklyTotal) * 100.0
                rawData["\(modelName):weekly_percent"] = formatPercent(weeklyPercent)
            }
        }

        return SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)
    }

    private func formatPercent(_ value: Double) -> String {
        // Format to 1 decimal place, e.g. "9.5" or "100.0"
        if value >= 100.0 {
            return "100.0"
        } else if value >= 10.0 {
            return String(format: "%.1f", value)
        } else if value >= 1.0 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }
}