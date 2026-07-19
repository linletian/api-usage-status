import XCTest
@testable import APIUsageStatus

final class KimiResponseParserTests: XCTestCase {

    private let parser = KimiResponseParser()

    /// Live response captured 2026-07-19 from `GET https://api.kimi.com/coding/v1/usages`
    /// (OAuth token, membership LEVEL_INTERMEDIATE). Quota numbers are JSON strings;
    /// `resetTime` carries 6-digit fractional seconds.
    private let liveResponseJSON = """
    {
      "user": { "userId": "d5vm6eumu6sf93n1flm0", "region": "REGION_CN", "membership": { "level": "LEVEL_INTERMEDIATE" }, "businessId": "" },
      "usage": { "limit": "100", "used": "1", "remaining": "99", "resetTime": "2026-07-26T05:20:54.627714Z" },
      "limits": [
        { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
          "detail": { "limit": "100", "used": "6", "remaining": "94", "resetTime": "2026-07-19T10:20:54.627714Z" } }
      ],
      "parallel": { "limit": "20" },
      "totalQuota": { "limit": "100", "remaining": "99" },
      "authentication": { "method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING" },
      "subType": "TYPE_PURCHASE"
    }
    """

    func testSuccessfulParse() throws {
        let response = try parser.parse(liveResponseJSON.data(using: .utf8)!)

        XCTAssertTrue(response.isAvailable)
        XCTAssertNil(response.currency)

        // 5h rolling window: used 6 / limit 100 → 6.0% used, 94.0% left
        XCTAssertEqual(response.rawData["kimi"], "6.0")
        XCTAssertEqual(response.rawData["kimi:status"], "1")
        XCTAssertEqual(response.rawData["kimi:remaining"], "94.0")

        // Weekly window: used 1 / limit 100 → 1.0% used, 99.0% left
        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "1.0")
        XCTAssertEqual(response.rawData["kimi:weekly_status"], "1")
        XCTAssertEqual(response.rawData["kimi:weekly_remaining"], "99.0")

        // Informational fields
        XCTAssertEqual(response.rawData["kimi:membership"], "LEVEL_INTERMEDIATE")
        XCTAssertEqual(response.rawData["kimi:parallel_limit"], "20")

        // Both windows must publish epoch-ms end times under the standard
        // `<key>:end_time` keys so RefreshService can render live countdowns.
        // The 6-digit fractional-seconds ISO 8601 must parse (not fall back to 0).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedWeeklyMs = Int64(
            formatter.date(from: "2026-07-26T05:20:54.627714Z")!.timeIntervalSince1970 * 1000
        )
        let expectedRollingMs = Int64(
            formatter.date(from: "2026-07-19T10:20:54.627714Z")!.timeIntervalSince1970 * 1000
        )
        XCTAssertEqual(response.rawData["kimi:weekly_percent:end_time"], String(expectedWeeklyMs))
        XCTAssertEqual(response.rawData["kimi:end_time"], String(expectedRollingMs))
    }

    func testNumericJsonNumbersAreTolerated() throws {
        // Same shape but with JSON numbers instead of string-typed numbers.
        let json = """
        {
          "usage": { "limit": 200, "used": 50, "resetTime": "2026-07-26T00:00:00Z" },
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": 100, "used": 25, "resetTime": "2026-07-19T12:00:00Z" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "25.0")
        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "25.0")
        XCTAssertEqual(response.rawData["kimi:weekly_status"], "1")
    }

    func testMissingQuotaBlocksReportZeroAndUnlimited() throws {
        // No `limits` and no `usage` — 5h reports 0%, weekly reports
        // unlimited (status "0"), end times are 0 (no countdown).
        let json = """
        { "user": { "membership": { "level": "LEVEL_FREE" } } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "0.0")
        XCTAssertEqual(response.rawData["kimi:status"], "0")
        XCTAssertEqual(response.rawData["kimi:remaining"], "100.0")
        XCTAssertEqual(response.rawData["kimi:end_time"], "0")
        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "0.0")
        XCTAssertEqual(response.rawData["kimi:weekly_status"], "0")
        XCTAssertEqual(response.rawData["kimi:weekly_remaining"], "100.0")
        XCTAssertEqual(response.rawData["kimi:weekly_percent:end_time"], "0")
        XCTAssertEqual(response.rawData["kimi:membership"], "LEVEL_FREE")
    }

    func testWeeklyLimitZeroIsTreatedAsUnlimited() throws {
        let json = """
        { "usage": { "limit": "0", "used": "0", "resetTime": "2026-07-26T00:00:00Z" } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "0.0")
        XCTAssertEqual(response.rawData["kimi:weekly_status"], "0")
    }

    func testSelectsThe300MinuteWindow() throws {
        // A non-300-minute entry first must not shadow the 5h window.
        let json = """
        {
          "limits": [
            { "window": { "duration": 60, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "10", "used": "5", "resetTime": "2026-07-19T11:00:00Z" } },
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "40", "resetTime": "2026-07-19T15:00:00Z" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "40.0")
        XCTAssertEqual(response.rawData["kimi:remaining"], "60.0")
    }

    func testFallsBackToFirstLimitsEntryWhenWindowUnknown() throws {
        let json = """
        {
          "limits": [
            { "window": { "duration": 1440, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "50", "used": "10", "resetTime": "2026-07-20T00:00:00Z" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "20.0")
        XCTAssertEqual(response.rawData["kimi:status"], "1")
    }

    func testResetTimeWithoutFractionalSecondsParses() throws {
        let json = """
        { "usage": { "limit": "100", "used": "10", "resetTime": "2026-07-26T05:20:54Z" } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedMs = Int64(
            formatter.date(from: "2026-07-26T05:20:54Z")!.timeIntervalSince1970 * 1000
        )
        XCTAssertEqual(response.rawData["kimi:weekly_percent:end_time"], String(expectedMs))
    }

    func testUnparseableResetTimeWritesZeroEndTime() throws {
        let json = """
        { "usage": { "limit": "100", "used": "10", "resetTime": "not-a-date" } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "10.0")
        XCTAssertEqual(response.rawData["kimi:weekly_percent:end_time"], "0")
    }

    func testNonNumericLimitThrows() {
        let json = """
        { "usage": { "limit": "abc", "used": "1" } }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
        }
    }

    func testMissingUsedFieldThrows() {
        let json = """
        { "usage": { "limit": "100" } }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
        }
    }

    func testInvalidJSONThrows() {
        let json = "not json".data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
        }
    }
}
