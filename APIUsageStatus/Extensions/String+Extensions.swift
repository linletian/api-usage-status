import Foundation

extension String {
    /// Validates if the string is a valid UUID v4 format.
    var isValidUUID: Bool {
        UUID(uuidString: self) != nil
    }

    /// Returns the currency symbol for a currency code.
    var currencySymbol: String {
        switch self.uppercased() {
        case "CNY":
            return "¥"
        case "USD":
            return "$"
        default:
            return self
        }
    }

    /// Trims whitespace from both ends.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the string is empty or contains only whitespace.
    var isBlank: Bool {
        trimmed.isEmpty
    }
}