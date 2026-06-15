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

    /// Validates if the string is a valid 2- or 3-character short name:
    /// uppercase letters and digits, e.g. "MX", "MAX", "OC5", "DS1".
    var isValidShortName: Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[A-Z0-9]{2,3}$") else { return false }
        let range = NSRange(startIndex..., in: self)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}