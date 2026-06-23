import XCTest
@testable import APIUsageStatus

final class CopilotResponseParserTests: XCTestCase {

    private let parser = CopilotResponseParser()

    func testSuccessfulParse() throws {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_reset_date_utc": "2026-07-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "percent_remaining": 73.33,
              "remaining": 220,
              "unlimited": false,
              "overage_count": 0,
              "overage_permitted": false
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.rawData["premium_interactions"], "26.7")
        XCTAssertEqual(response.rawData["premium_interactions:unlimited"], "false")
        XCTAssertEqual(response.rawData["premium_interactions:entitlement"], "300")
        XCTAssertEqual(response.rawData["premium_interactions:remaining"], "220")
        XCTAssertEqual(response.rawData["premium_interactions:percent_remaining"], "73.3")
        XCTAssertEqual(response.rawData["premium_interactions:reset_date"], "2026-07-01T00:00:00Z")
        XCTAssertEqual(response.rawData["premium_interactions:plan"], "pro")
        XCTAssertEqual(response.rawData["premium_interactions:overage_count"], "0")
        XCTAssertEqual(response.rawData["premium_interactions:overage_permitted"], "false")

        // Parser must also write the standard <key>:end_time ms key so
        // `RefreshService` can populate `cycleEndTime` for the live
        // "Xh Ym remaining" countdown via the same code path as other
        // suppliers. The expected ms is the Z-suffixed ISO 8601 value
        // converted to Unix epoch milliseconds.
        let expectedEndTimeMs = Int64(
            ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!.timeIntervalSince1970 * 1000
        )
        XCTAssertEqual(
            response.rawData["premium_interactions:end_time"],
            String(expectedEndTimeMs),
            "Parser must derive end_time ms from quota_reset_date_utc"
        )
    }

    func testUnlimitedPlanReportsZeroUsage() throws {
        let json = """
        {
          "copilot_plan": "pro_plus",
          "quota_reset_date_utc": "2026-07-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 1500,
              "percent_remaining": 0,
              "remaining": 0,
              "unlimited": true,
              "overage_count": 0,
              "overage_permitted": true
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["premium_interactions"], "0.0")
        XCTAssertEqual(response.rawData["premium_interactions:unlimited"], "true")
        XCTAssertEqual(response.rawData["premium_interactions:plan"], "pro_plus")
    }

    func testOverageData() throws {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_reset_date_utc": "2026-07-01T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "percent_remaining": 0,
              "remaining": 0,
              "unlimited": false,
              "overage_count": 42,
              "overage_permitted": true
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["premium_interactions"], "100.0")
        XCTAssertEqual(response.rawData["premium_interactions:overage_count"], "42")
        XCTAssertEqual(response.rawData["premium_interactions:overage_permitted"], "true")
    }

    func testMissingQuotaSnapshotsThrows() {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_reset_date_utc": "2026-07-01T00:00:00Z"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
        }
    }

    func testMissingPremiumInteractionsThrows() {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {}
        }
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

    func testMissingPercentRemainingThrows() {
        // Without percent_remaining, the parser would compute usagePercent = 100
        // and trigger a false 100% critical alert. Must throw instead.
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 220,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            XCTAssertTrue(message.contains("percent_remaining"), "Error should mention the missing field: \(message)")
        }
    }

    func testMissingEntitlementThrows() {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "percent_remaining": 73.33,
              "remaining": 220,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            XCTAssertTrue(message.contains("entitlement"), "Error should mention the missing field: \(message)")
        }
    }

    func testMissingRemainingThrows() {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "percent_remaining": 73.33,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            XCTAssertTrue(message.contains("remaining"), "Error should mention the missing field: \(message)")
        }
    }

    func testOverageCountMissingDoesNotThrow() {
        // overage_count is optional (reserved for future use), missing is fine.
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "percent_remaining": 73.33,
              "remaining": 220,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        let response = try? parser.parse(json)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.rawData["premium_interactions:overage_count"], "0")
    }

    func testNonNumericCoreFieldThrows() {
        // Field present but wrong type — should throw, not silently coerce.
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": "not a number",
              "percent_remaining": 73.33,
              "remaining": 220,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            // Error should distinguish "non-numeric" from "missing" and surface the bad value.
            XCTAssertTrue(message.contains("Non-numeric"), "Error should say Non-numeric, got: \(message)")
            XCTAssertTrue(message.contains("entitlement"), "Error should mention the field name: \(message)")
            XCTAssertTrue(message.contains("not a number"), "Error should include the actual value: \(message)")
        }
    }

    func testMissingFieldErrorMessageDistinguishesFromNonNumeric() {
        // Missing-field errors should be distinguishable from non-numeric
        // errors so maintainers reading logs can tell them apart.
        let json = """
        {
          "copilot_plan": "pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 220,
              "unlimited": false
            }
          }
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard case RefreshError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            XCTAssertTrue(message.contains("Missing"), "Missing-field error should say Missing, got: \(message)")
            XCTAssertFalse(message.contains("Non-numeric"), "Missing-field error should NOT say Non-numeric: \(message)")
        }
    }

    // MARK: - parseISO8601ToMs (static helper)

    /// Pin the canonical Copilot date format: `2026-07-01T00:00:00Z`.
    /// Pinned via two independent calculations (ISO8601DateFormatter and
    /// raw seconds arithmetic) so a regression in either the parser or
    /// the test's own reference calculation surfaces.
    func testParseISO8601ToMsCanonicalZuluFormat() {
        let expected = Int64(
            Date(timeIntervalSince1970: 1782864000).timeIntervalSince1970 * 1000
        )
        // Sanity: 2026-07-01T00:00:00Z == 1_782_864_000 epoch seconds.
        XCTAssertEqual(expected, 1_782_864_000_000)

        XCTAssertEqual(
            CopilotResponseParser.parseISO8601ToMs("2026-07-01T00:00:00Z"),
            expected
        )
    }

    /// Copilot occasionally returns date-only strings without a time
    /// component. The helper must fall back to parsing as UTC midnight
    /// rather than returning nil — otherwise those responses would lose
    /// their `end_time` ms key and the live countdown would silently
    /// disappear.
    func testParseISO8601ToMsDateOnlyFallsBackToUTCMidnight() {
        let expected = Int64(
            Date(timeIntervalSince1970: 1782864000).timeIntervalSince1970 * 1000
        )
        XCTAssertEqual(
            CopilotResponseParser.parseISO8601ToMs("2026-07-01"),
            expected
        )
    }

    /// Empty input must return nil so the parser omits the `end_time`
    /// key (rather than writing a stale zero ms that would clobber
    /// any previous good value in derived state).
    func testParseISO8601ToMsEmptyStringReturnsNil() {
        XCTAssertNil(CopilotResponseParser.parseISO8601ToMs(""))
    }

    /// Garbage input must not throw — the parser is the only hard-fail
    /// layer for the core numeric fields. A bad `quota_reset_date_utc`
    /// is a soft miss: the response should still parse, just without
    /// the `end_time` key.
    func testParseISO8601ToMsGarbageReturnsNil() {
        XCTAssertNil(CopilotResponseParser.parseISO8601ToMs("not a date"))
        XCTAssertNil(CopilotResponseParser.parseISO8601ToMs("2026-13-99T25:99:99Z"))
        XCTAssertNil(CopilotResponseParser.parseISO8601ToMs("🦀"))
    }

    /// When `quota_reset_date_utc` is malformed, the parser must still
    /// succeed (the core numeric fields validate independently) but
    /// omit the `end_time` key. This locks the soft-fail behavior.
    func testMalformedResetDateOmitsEndTimeKey() throws {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_reset_date_utc": "not a date",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "percent_remaining": 73.33,
              "remaining": 220,
              "unlimited": false,
              "overage_count": 0,
              "overage_permitted": false
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)
        XCTAssertTrue(response.isAvailable)
        // `reset_date` is preserved as a raw string for debugging;
        // `end_time` is the derived ms key — must be absent.
        XCTAssertEqual(response.rawData["premium_interactions:reset_date"], "not a date")
        XCTAssertNil(
            response.rawData["premium_interactions:end_time"],
            "Malformed reset date must not write end_time"
        )
    }
}
