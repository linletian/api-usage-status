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

    func testUnparseableRollingResetTimeWritesZeroEndTime() throws {
        let json = """
        {
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "10", "resetTime": "not-a-date" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "10.0")
        XCTAssertEqual(response.rawData["kimi:end_time"], "0")
        XCTAssertEqual(
            response.metricCycleEndPolicies["kimi"],
            .retainPreviousIfResponseMissing,
            "Invalid 5h resetTime must declare the retain-previous policy"
        )
        XCTAssertNil(
            response.metricCycleEndPolicies["kimi:weekly_percent"],
            "Weekly window is unaffected by the 5h policy"
        )
    }

    func testMissingRollingLimitDetailDeclaresRetainPolicy() throws {
        let json = """
        { "user": { "membership": { "level": "LEVEL_FREE" } } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "0.0")
        XCTAssertEqual(response.rawData["kimi:end_time"], "0")
        XCTAssertEqual(
            response.metricCycleEndPolicies["kimi"],
            .retainPreviousIfResponseMissing,
            "Empty limits must declare the retain-previous policy for the 5h window"
        )
    }

    func testValidRollingResetTimeDoesNotDeclarePolicy() throws {
        let json = """
        {
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "10", "resetTime": "2026-07-26T05:20:54.627714Z" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertNotEqual(response.rawData["kimi:end_time"], "0")
        XCTAssertNil(
            response.metricCycleEndPolicies["kimi"],
            "Valid 5h resetTime must not declare the retain-previous policy"
        )
    }

    /// A bad weekly `resetTime` must not turn on the 5h `retainPrevious` policy.
    /// The fixture mirrors a partial-degrade response: the 5h window is present
    /// and valid, the weekly `usage` block has an unparseable `resetTime`. The
    /// 5h policy decision is independent of weekly data — a corrupted weekly
    /// reset must not pollute the 5h countdown policy.
    func testUnparseableWeeklyResetTimeDoesNotDeclareFiveHourPolicy() throws {
        let json = """
        {
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "used": "10", "resetTime": "2026-07-26T05:20:54.627714Z" } }
          ],
          "usage": { "limit": "100", "used": "10", "resetTime": "not-a-date" }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        // Weekly end_time falls back to 0 (unparseable) but that must not
        // affect the 5h decision.
        XCTAssertEqual(response.rawData["kimi:weekly_percent:end_time"], "0")
        XCTAssertNil(
            response.metricCycleEndPolicies["kimi"],
            "Bad weekly resetTime must not turn on the 5h fallback policy"
        )
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

    /// Real production shape captured from 24h of logs (2026-08-08/09): the server
    /// serializes with proto3 JSON semantics and omits `used` when the counter is 0.
    /// Missing `used` must parse as 0% — this was the dominant failure mode in
    /// production (642 consecutive refresh failures, see
    /// docs/kimi-api-failures-investigation.md §5).
    func testMissingUsedInWeeklyUsageTreatedAsZero() throws {
        let json = """
        { "usage": { "limit": "100", "remaining": "100", "resetTime": "2026-08-16T05:20:54.627714Z" } }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "0.0")
        XCTAssertEqual(response.rawData["kimi:weekly_status"], "1")
        XCTAssertEqual(response.rawData["kimi:weekly_remaining"], "100.0")
    }

    /// The exact 5h `detail` shape the server returned ~633 times in 24h while the
    /// rolling window was untouched: `limit` + `remaining` + `resetTime`, no `used`.
    func testMissingUsedInRollingDetailTreatedAsZero() throws {
        let json = """
        {
          "usage": { "limit": "100", "used": "100", "resetTime": "2026-08-09T05:20:54.627714Z" },
          "limits": [
            { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
              "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-08-08T10:20:54.627714Z" } }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["kimi"], "0.0")
        XCTAssertEqual(response.rawData["kimi:status"], "1")
        XCTAssertEqual(response.rawData["kimi:remaining"], "100.0")
        XCTAssertEqual(response.rawData["kimi:end_time"], "1786184454627")
        XCTAssertEqual(response.rawData["kimi:weekly_percent"], "100.0")
    }

    /// Zero-omission tolerance does not extend to garbage: a present but
    /// non-numeric `used` must still fail the refresh, same as `limit`.
    func testNonNumericUsedThrows() {
        let json = """
        { "usage": { "limit": "100", "used": "abc" } }
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
