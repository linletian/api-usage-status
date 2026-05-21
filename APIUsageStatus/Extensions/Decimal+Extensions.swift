import Foundation

extension Decimal {
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

    func isLess(than other: Decimal) -> Bool {
        self < other
    }

    func isGreater(than other: Decimal) -> Bool {
        self > other
    }

    func isEqual(to other: Decimal) -> Bool {
        self == other
    }

    var isNegative: Bool {
        self < 0
    }

    var isZero: Bool {
        self == 0
    }
}