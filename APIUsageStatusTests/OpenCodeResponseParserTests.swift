import XCTest
@testable import APIUsageStatus

final class OpenCodeResponseParserTests: XCTestCase {
    let parser = OpenCodeResponseParser()

    // Fixture captured 2026-06-15 against the real `~/.local/share/opencode/opencode.db`.
    // `five_hour_ms` and `week_start_ms` are baked into the SQL by the supplier; only
    // the row content matters here.
    private let realPrimaryJSON = """
    [
      {
        "five_hour_cost": 20.118024910000017,
        "weekly_cost": 25.05777525,
        "five_hour_oldest_ms": 1781490257796,
        "anchor_ms": 1772019366076
      }
    ]
    """.data(using: .utf8)!

    private let realMonthlyJSON = """
    [
      {
        "monthly_cost": 58.416045410000045
      }
    ]
    """.data(using: .utf8)!

    func testParsePrimaryRealFixture() throws {
        let p = try parser.parsePrimary(realPrimaryJSON)
        XCTAssertEqual(p.fiveHourCost, 20.118, accuracy: 0.001)
        XCTAssertEqual(p.weeklyCost, 25.058, accuracy: 0.001)
        XCTAssertEqual(p.fiveHourOldestMs, 1781490257796)
        XCTAssertEqual(p.anchorMs, 1772019366076)
    }

    func testParsePrimaryAcceptsBareObject() throws {
        let json = """
        {"five_hour_cost": 1.0, "weekly_cost": 2.0, "five_hour_oldest_ms": 100, "anchor_ms": 50}
        """.data(using: .utf8)!
        let p = try parser.parsePrimary(json)
        XCTAssertEqual(p.fiveHourCost, 1.0)
        XCTAssertEqual(p.weeklyCost, 2.0)
        XCTAssertEqual(p.fiveHourOldestMs, 100)
        XCTAssertEqual(p.anchorMs, 50)
    }

    func testParseMonthlyRealFixture() throws {
        let cost = try parser.parseMonthly(realMonthlyJSON)
        XCTAssertEqual(cost, 58.416, accuracy: 0.001)
    }

    func testBuildParsedAllDimensions() {
        let primary = OpenCodeResponseParser.ParsedPrimary(
            fiveHourCost: 6.0,
            weeklyCost: 15.0,
            anchorMs: 1_772_019_366_076,
            fiveHourOldestMs: 1_781_490_257_796
        )
        let now = Date(timeIntervalSince1970: 1_783_000_000) // 2026-06-15
        let p = parser.buildParsed(primary: primary, monthlyCost: 30.0, now: now)

        XCTAssertEqual(p.fiveHour.used, 6.0)
        XCTAssertEqual(p.fiveHour.limit, OpenCodeGoLimits.fiveHour, accuracy: 0.001)
        XCTAssertEqual(p.fiveHour.percent, 50.0, accuracy: 0.01)
        XCTAssertNotNil(p.fiveHour.endTimeMs)

        XCTAssertEqual(p.weekly.used, 15.0)
        XCTAssertEqual(p.weekly.limit, OpenCodeGoLimits.weekly, accuracy: 0.001)
        XCTAssertEqual(p.weekly.percent, 50.0, accuracy: 0.01)

        XCTAssertEqual(p.monthly.used, 30.0)
        XCTAssertEqual(p.monthly.limit, OpenCodeGoLimits.monthly, accuracy: 0.001)
        XCTAssertEqual(p.monthly.percent, 50.0, accuracy: 0.01)
    }

    // MARK: - Window algorithm tests

    func testFiveHourResetWithOldest() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = Int64(1_700_000_000 * 1000)
        let reset = OpenCodeResponseParser.fiveHourResetDate(from: oldest, fallback: now)
        XCTAssertEqual(reset.timeIntervalSince(now), 5 * 3600, accuracy: 1)
    }

    func testFiveHourResetNoMessages() {
        let now = Date()
        let reset = OpenCodeResponseParser.fiveHourResetDate(from: nil, fallback: now)
        XCTAssertEqual(reset.timeIntervalSince(now), 5 * 3600, accuracy: 1)
    }

    func testNextMondayMidnightUTC() {
        // 2026-06-15 is a Monday at some time-of-day. The reset should be
        // exactly 7 days later at 00:00 UTC.
        let monday = Date(timeIntervalSince1970: 1_783_000_000)
        let reset = OpenCodeResponseParser.nextMondayMidnightUTC(from: monday)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.weekday, .hour, .minute, .second], from: reset)
        XCTAssertEqual(comps.weekday, 2) // Monday
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)
    }

    func testNextMondayMidnightFromMidweek() {
        // Pick a Wednesday, 2026-06-17 12:00 UTC.
        let wednesday = Date(timeIntervalSince1970: 1_783_432_800)
        let reset = OpenCodeResponseParser.nextMondayMidnightUTC(from: wednesday)
        // 4 days + 12 hours ahead = 2026-06-22 (Monday) 00:00 UTC
        let expected = Date(timeIntervalSince1970: 1_783_948_800)
        XCTAssertEqual(reset.timeIntervalSince(expected), 0, accuracy: 60)
    }

    func testAnchoredMonthEndInPastThisMonth() {
        // Anchor 25th, now mid-month → end is this month's 25th
        let anchor = Date(timeIntervalSince1970: 1_772_019_366) // 2026-02-25
        let now = Date(timeIntervalSince1970: 1_782_000_000)   // 2026-06-10
        let end = OpenCodeResponseParser.anchoredMonthEnd(now: now, anchor: anchor)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: end)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 25)
        XCTAssertEqual(comps.hour, 11)
    }

    func testAnchoredMonthEndAlreadyPassed() {
        // Anchor 25th, now past this month's 25th → end is next month's 25th
        let anchor = Date(timeIntervalSince1970: 1_772_019_366) // 2026-02-25
        let now = Date(timeIntervalSince1970: 1_784_000_000)   // 2026-06-26
        let end = OpenCodeResponseParser.anchoredMonthEnd(now: now, anchor: anchor)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day], from: end)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 25)
    }

    // MARK: - makeResponse (rawData shape)

    func testMakeResponseShape() {
        let primary = OpenCodeResponseParser.ParsedPrimary(
            fiveHourCost: 1.0,
            weeklyCost: 2.0,
            anchorMs: 1_772_019_366_076,
            fiveHourOldestMs: 1_781_490_257_796
        )
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let parsed = parser.buildParsed(primary: primary, monthlyCost: 3.0, now: now)
        let response = OpenCodeSupplier.makeResponse(from: parsed)

        // 5h: percent = 1/12 * 100 ≈ 8.33
        XCTAssertEqual(response.rawData["5h"], "8.3")
        XCTAssertEqual(response.rawData["5h:used"], "1.00")
        XCTAssertEqual(response.rawData["5h:limit"], "12.00")
        XCTAssertNotNil(response.rawData["5h:end_time"])

        XCTAssertEqual(response.rawData["weekly:used"], "2.00")
        XCTAssertEqual(response.rawData["weekly:limit"], "30.00")
        XCTAssertNotNil(response.rawData["weekly:end_time"])

        XCTAssertEqual(response.rawData["monthly:used"], "3.00")
        XCTAssertEqual(response.rawData["monthly:limit"], "60.00")
        XCTAssertNotNil(response.rawData["monthly:end_time"])

        XCTAssertEqual(response.currency, "USD")
        XCTAssertTrue(response.isAvailable)
    }
}
