import Foundation

// MARK: - DeepSeekResponseParser

/// Parses DeepSeek balance API responses.
/// API response format per PRD Appendix A:
/// {
///   "is_available": true,
///   "balance_infos": [
///     { "currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00" }
///   ]
/// }
struct DeepSeekResponseParser {
    /// Parses raw JSON data into a SupplierResponse.
    /// - Parameter data: Raw data from the DeepSeek API
    /// - Returns: SupplierResponse with balance data
    func parse(_ data: Data) throws -> SupplierResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.parsingError("Invalid JSON from DeepSeek API")
        }

        // Parse is_available
        let isAvailable = json["is_available"] as? Bool ?? false

        guard let balanceInfos = json["balance_infos"] as? [[String: Any]] else {
            throw RefreshError.parsingError("Missing or invalid balance_infos")
        }

        // Select the appropriate balance record:
        // Priority 1: CNY record
        // Priority 2: first record in the list
        var selectedRecord: [String: Any]?
        for record in balanceInfos {
            if let currency = record["currency"] as? String, currency == "CNY" {
                selectedRecord = record
                break
            }
        }

        // If no CNY record found, use the first one
        if selectedRecord == nil {
            selectedRecord = balanceInfos.first
        }

        guard let record = selectedRecord else {
            throw RefreshError.parsingError("No balance info available")
        }

        // Extract fields
        let toppedUpBalance = stringValue(record["topped_up_balance"])
        let totalBalance = stringValue(record["total_balance"])
        let grantedBalance = stringValue(record["granted_balance"])
        let currency = record["currency"] as? String

        var rawData: [String: String] = [
            "balance": toppedUpBalance,
            "total_balance": totalBalance,
            "granted_balance": grantedBalance,
        ]

        return SupplierResponse(rawData: rawData, currency: currency, isAvailable: isAvailable)
    }

    private func stringValue(_ value: Any?) -> String {
        if let str = value as? String {
            return str
        } else if let num = value as? NSNumber {
            return num.stringValue
        }
        return "0"
    }
}