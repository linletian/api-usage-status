import Foundation

// MARK: - SupplierResponse

/// Represents the parsed response from a supplier API.
/// The rawData dictionary contains dimension-identified values.
struct SupplierResponse: Equatable {
    /// Maps internal dimension identifiers to their values.
    /// For MiniMax: model_name values (e.g., "MiniMax-M2.7", "speech-hd", "music-2.6")
    /// For DeepSeek: "balance"
    let rawData: [String: String]

    /// The currency returned by the API (e.g., "CNY", "USD"), if present.
    let currency: String?

    /// Whether the account is available (DeepSeek-specific).
    let isAvailable: Bool

    init(rawData: [String: String], currency: String? = nil, isAvailable: Bool = true) {
        self.rawData = rawData
        self.currency = currency
        self.isAvailable = isAvailable
    }

    func value(forDimension dimension: String) -> String? {
        rawData[dimension]
    }
}