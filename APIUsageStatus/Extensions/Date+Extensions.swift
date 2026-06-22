import Foundation

extension Date {
    /// Returns the start of the current day (00:00:00)
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Returns the start of the current week (Sunday 00:00:00)
    var startOfWeek: Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        components.weekday = 1 // Sunday
        return calendar.date(from: components) ?? self
    }

    /// Days until end of this week (Saturday 23:59:59)
    var daysUntilEndOfWeek: Int {
        let calendar = Calendar.current
        let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek)!
        let startOfEndDay = calendar.startOfDay(for: endOfWeek)
        let components = calendar.dateComponents([.day], from: self, to: startOfEndDay)
        return max(0, components.day ?? 0)
    }

    /// Whether this date is the same day as another date
    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    /// Whether this date is today
    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    /// Returns date string in "yyyy-MM-dd" format
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }

    /// Days since another date (absolute difference)
    func daysSince(_ other: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: other.startOfDay, to: self.startOfDay)
        return abs(components.day ?? 0)
    }

    /// Days from this date to another date
    func daysUntil(_ other: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: self.startOfDay, to: other.startOfDay)
        return max(0, components.day ?? 0)
    }

    /// Format the elapsed time from `self` to now as "Xm" / "Xh Ym" / "Xd".
    /// Returns "1m" for future or sub-minute elapsed times so the UI never
    /// shows "0m" or a negative value.
    var timeSinceNow: String {
        let totalSeconds = max(0, Int(Date().timeIntervalSince(self)))
        return totalSeconds.formattedDuration
    }
}

extension Int {
    /// Format non-negative seconds as "Xm" / "Xh Ym" / "Xd". Sub-minute
    /// values are rounded up to "1m" so the UI never shows "0m". Used by
    /// `Date.timeSinceNow` and `UsageCardView` for the window status row.
    var formattedDuration: String {
        if self >= 86_400 {
            return "\(self / 86_400)d"
        } else if self >= 3_600 {
            let hours = self / 3_600
            let minutes = (self % 3_600) / 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        } else {
            return "\(Swift.max(1, self / 60))m"
        }
    }
}