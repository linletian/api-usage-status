import Foundation

extension Decimal {
    /// Initialize Decimal from a string safely, returning nil on failure.
    init?(string: String) {
        guard let value = Decimal(string: string) else {
            // Try removing trailing zeros
            var trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return nil
            }
            guard let value = Decimal(string: trimmed) else {
                return nil
            }
            self = value
            return
        }
        self = value
    }

    /// Returns a string formatted to the specified decimal places.
    func formatted(decimalPlaces: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimalPlaces
        formatter.maximumFractionDigits = decimalPlaces
        return formatter.string(from: self as NSDecimalNumber) ?? "\(self)"
    }

    /// Subtraction as Decimal
    func minus(_ other: Decimal) -> Decimal {
        var result = Decimal()
        var left = self
        var right = other
        NSDecimalSubtract(&result, &left, &right, .plain)
        return result
    }

    /// Addition as Decimal
    func plus(_ other: Decimal) -> Decimal {
        var result = Decimal()
        var left = self
        var right = other
        NSDecimalAdd(&result, &left, &right, .plain)
        return result
    }

    /// Division as Decimal
    func divided(by other: Decimal) -> Decimal {
        var result = Decimal()
        var left = self
        var right = other
        NSDecimalDivide(&result, &left, &right, .plain)
        return result
    }

    /// Multiplication as Decimal
    func multiplied(by other: Decimal) -> Decimal {
        var result = Decimal()
        var left = self
        var right = other
        NSDecimalMultiply(&result, &left, &right, .plain)
        return result
    }

    /// Comparison: self < other
    func isLess(than other: Decimal) -> Bool {
        var result = NSDecimalCompare(self as NSDecimalNumber, other as NSDecimalNumber)
        return result == .orderedAscending
    }

    /// Comparison: self > other
    func isGreater(than other: Decimal) -> Bool {
        var result = NSDecimalCompare(self as NSDecimalNumber, other as NSDecimalNumber)
        return result == .orderedDescending
    }

    /// Comparison: self == other
    func isEqual(to other: Decimal) -> Bool {
        var result = NSDecimalCompare(self as NSDecimalNumber, other as NSDecimalNumber)
        return result == .orderedSame
    }

    /// Is negative
    var isNegative: Bool {
        NSDecimalCompare(self as NSDecimalNumber, 0 as NSDecimalNumber) == .orderedAscending
    }

    /// Is zero
    var isZero: Bool {
        NSDecimalCompare(self as NSDecimalNumber, 0 as NSDecimalNumber) == .orderedSame
    }
}