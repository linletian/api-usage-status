import XCTest
@testable import APIUsageStatus

final class BalanceCalculatorTests: XCTestCase {

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private var today: String {
        dateFormatter.string(from: Date())
    }

    private var yesterday: String {
        let d = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        return dateFormatter.string(from: d)
    }

    func testFirstRefreshCreatesBaseline() {
        let result = BalanceCalculator.update(snapshot: nil, currentToppedUp: "100.00")

        XCTAssertEqual(result.snapshot.todayUsage, "0")
        XCTAssertEqual(result.snapshot.latestToppedUp, "100.00")
        XCTAssertEqual(result.snapshot.todayDate, today)
        XCTAssertEqual(result.snapshot.history.count, 0)
    }

    func testNormalConsumption() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "0")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "95.00")

        XCTAssertEqual(result.snapshot.todayUsage, "5.00")
        XCTAssertEqual(result.snapshot.latestToppedUp, "95.00")
    }

    func testMultipleConsumptionsAccumulate() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "0")
        let result1 = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "95.00")
        XCTAssertEqual(result1.snapshot.todayUsage, "5.00")

        let result2 = BalanceCalculator.update(snapshot: result1.snapshot, currentToppedUp: "90.00")
        XCTAssertEqual(result2.snapshot.todayUsage, "10.00")
        XCTAssertEqual(result2.snapshot.latestToppedUp, "90.00")
    }

    func testDayChangeArchivesYesterday() {
        let pastDate = "2025-12-25"
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: pastDate, todayUsage: "3.50")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "100.00")

        XCTAssertEqual(result.snapshot.todayDate, today)
        XCTAssertEqual(result.snapshot.todayUsage, "0")
        XCTAssertEqual(result.snapshot.history.count, 1)
        XCTAssertEqual(result.snapshot.history[0].date, pastDate)
        XCTAssertEqual(result.snapshot.history[0].usage, "3.50")
    }

    func testRechargeDetection() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "5.00")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "150.00")

        XCTAssertEqual(result.snapshot.todayUsage, "5.00")
        XCTAssertEqual(result.snapshot.latestToppedUp, "150.00")
        XCTAssertEqual(result.snapshot.lastTopupDate, today)
    }

    func testNoConsumptionWhenEqual() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "5.00")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "100.00")

        XCTAssertEqual(result.snapshot.todayUsage, "5.00")
        XCTAssertEqual(result.snapshot.latestToppedUp, "100.00")
    }

    func testHistoryTrimming() {
        let pastDate = "2025-12-25"
        let snapshot = BalanceSnapshot(
            latestToppedUp: "100.00",
            todayDate: pastDate,
            todayUsage: "2.00",
            history: [
                DailyUsageEntry(date: "2025-12-24", usage: "3.00"),
                DailyUsageEntry(date: "2025-12-23", usage: "4.00"),
                DailyUsageEntry(date: "2025-12-22", usage: "5.00"),
            ]
        )
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "100.00", retentionDays: 2)

        XCTAssertEqual(result.snapshot.history.count, 2)
        XCTAssertEqual(result.snapshot.history[0].date, pastDate)
        XCTAssertEqual(result.snapshot.history[1].date, "2025-12-24")
    }

    func testUnlimitedRetention() {
        let pastDate = "2025-12-25"
        let snapshot = BalanceSnapshot(
            latestToppedUp: "100.00",
            todayDate: pastDate,
            todayUsage: "2.00",
            history: [
                DailyUsageEntry(date: "2025-12-24", usage: "3.00"),
                DailyUsageEntry(date: "2025-12-23", usage: "4.00"),
                DailyUsageEntry(date: "2025-12-22", usage: "5.00"),
            ]
        )
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "100.00", retentionDays: 0)

        XCTAssertEqual(result.snapshot.history.count, 4)
    }

    func testDailyAveragesCurrentWeek() {
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!

        let snapshot = BalanceSnapshot(
            latestToppedUp: "100.00",
            todayDate: today,
            todayUsage: "2.00",
            history: [
                DailyUsageEntry(date: dateFormatter.string(from: twoDaysAgo), usage: "4.00"),
                DailyUsageEntry(date: dateFormatter.string(from: threeDaysAgo), usage: "2.00"),
            ]
        )
        let averages = BalanceCalculator.calculateDailyAverages(snapshot: snapshot, periods: [.currentWeek])

        let avg = averages[.currentWeek]
        XCTAssertNotNil(avg)
        XCTAssertTrue(avg!.isGreater(than: Decimal(0)))
    }

    func testDailyAveragesLast30Days() {
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date())!

        let snapshot = BalanceSnapshot(
            latestToppedUp: "100.00",
            todayDate: today,
            todayUsage: "3.00",
            history: [
                DailyUsageEntry(date: dateFormatter.string(from: fiveDaysAgo), usage: "6.00"),
                DailyUsageEntry(date: dateFormatter.string(from: tenDaysAgo), usage: "4.00"),
            ]
        )
        let averages = BalanceCalculator.calculateDailyAverages(snapshot: snapshot, periods: [.last30Days])

        let avg = averages[.last30Days]
        XCTAssertNotNil(avg)
        XCTAssertTrue(avg!.isGreater(than: Decimal(0)))
    }

    func testDecimalPrecision() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "0")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "95.50")

        XCTAssertEqual(result.snapshot.todayUsage, "4.50")
    }

    func testConsumptionAfterDayChange() {
        let pastDate = "2025-12-25"
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: pastDate, todayUsage: "3.50")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "95.00")

        XCTAssertEqual(result.snapshot.todayDate, today)
        XCTAssertEqual(result.snapshot.todayUsage, "5.00")
        XCTAssertEqual(result.snapshot.history.count, 1)
        XCTAssertEqual(result.snapshot.history[0].usage, "3.50")
    }

    func testEmptyHistoryAverage() {
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: today, todayUsage: "0", history: [])
        let averages = BalanceCalculator.calculateDailyAverages(snapshot: snapshot, periods: [.currentWeek])

        let avg = averages[.currentWeek]
        XCTAssertNotNil(avg)
        XCTAssertEqual(avg!, Decimal(0))
    }

    func testDayChangeThenRecharge() {
        let pastDate = "2025-12-25"
        let snapshot = BalanceSnapshot(latestToppedUp: "100.00", todayDate: pastDate, todayUsage: "3.50")
        let result = BalanceCalculator.update(snapshot: snapshot, currentToppedUp: "120.00")

        XCTAssertEqual(result.snapshot.todayDate, today)
        XCTAssertEqual(result.snapshot.todayUsage, "0")
        XCTAssertEqual(result.snapshot.latestToppedUp, "120.00")
        XCTAssertEqual(result.snapshot.history.count, 1)
        XCTAssertEqual(result.snapshot.history[0].usage, "3.50")
    }
}
