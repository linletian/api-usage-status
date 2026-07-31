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

        XCTAssertEqual(response.rawData["premium_interactions"], "114.0")
        XCTAssertEqual(response.rawData["premium_interactions:overage_count"], "42")
        XCTAssertEqual(response.rawData["premium_interactions:overage_permitted"], "true")
    }

    /// Sampled live from `https://api.github.com/copilot_internal/user` on
    /// 2026-07-30. GitHub stopped flipping `overage_permitted` to true when
    /// the user is over-budget and truncates `percent_remaining` to 0, so
    /// the legacy overage branch must no longer be the only path that
    /// produces a percent > 100. Asserts the parser falls through to the
    /// `credits_used > entitlement` / `remaining < 0` signal and reports
    /// 115% instead of clamping at 100.
    func testOverageDataNewApiShape() throws {
        let json = """
        {
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2026-08-01T00:00:00.000Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 7000,
              "percent_remaining": 0.0,
              "remaining": -1055,
              "unlimited": false,
              "overage_count": 1000,
              "overage_permitted": false,
              "credits_used": 8054,
              "quota_remaining": -1054.2
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        // 8054 / 7000 * 100 = 115.0571... → "115.1"
        XCTAssertEqual(response.rawData["premium_interactions"], "115.1")
        XCTAssertEqual(response.rawData["premium_interactions:credits_used"], "8054")
        XCTAssertEqual(response.rawData["premium_interactions:remaining"], "-1055")
        XCTAssertEqual(response.rawData["premium_interactions:overage_permitted"], "false")
        XCTAssertEqual(response.rawData["premium_interactions:quota_remaining"], "-1054.2")
    }

    /// Same over-budget signal but without `credits_used` (e.g. a future
    /// API drop or a slightly different snapshot). The parser must still
    /// detect overage via `remaining < 0` and fall back to a formula
    /// that does not double-count `overage_count` on top of a negative
    /// `remaining` (the new shape already embeds overage in `remaining`).
    func testOverageDetectedWithoutCreditsUsed() throws {
        let json = """
        {
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2026-08-01T00:00:00.000Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 100,
              "percent_remaining": 0,
              "remaining": -10,
              "unlimited": false,
              "overage_count": 10,
              "overage_permitted": false
            }
          }
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        // `remaining < 0` ⇒ use `entitlement - remaining` (no `+ overage_count`,
        // which would re-add the overage already in `remaining`).
        // (100 - (-10)) / 100 * 100 = 110
        XCTAssertEqual(response.rawData["premium_interactions"], "110.0")
        // `quota_remaining` defaults to 0 in this fixture — make sure the
        // parser still surfaces it for diagnostics.
        XCTAssertEqual(response.rawData["premium_interactions:quota_remaining"], "0.0")
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

    /// Copilot may return ISO 8601 with fractional seconds
    /// (e.g. "2026-07-01T00:00:00.000Z"). The parser must handle
    /// this format so `end_time` is not silently dropped.
    func testParseISO8601ToMsWithFractionalSeconds() {
        let result = CopilotResponseParser.parseISO8601ToMs("2026-07-01T00:00:00.000Z")
        XCTAssertNotNil(result, "Fractional seconds format must parse successfully")
        // 2026-07-01T00:00:00.000Z == 1_782_864_000_000 ms
        XCTAssertEqual(result, 1_782_864_000_000)
    }

    func testParseISO8601ToMsWithFractionalSecondsNonZero() {
        let result = CopilotResponseParser.parseISO8601ToMs("2026-07-01T12:30:45.500Z")
        XCTAssertNotNil(result)
        // 2026-07-01T12:30:45.500Z == 1_782_909_045_500 ms
        XCTAssertEqual(result, 1_782_909_045_500)
    }

    /// `nextMonthlyResetMs()` must return a positive epoch-ms value
    /// that lands on the first day of a future month at UTC midnight.
    func testNextMonthlyResetMsReturnsFirstOfNextMonthMidnightUTC() {
        let ms = CopilotResponseParser.nextMonthlyResetMs()
        XCTAssertGreaterThan(ms, 0, "Monthly reset must be > 0")

        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        let day = utcCalendar.component(.day, from: date)
        let hour = utcCalendar.component(.hour, from: date)
        let minute = utcCalendar.component(.minute, from: date)
        let second = utcCalendar.component(.second, from: date)

        XCTAssertEqual(day, 1, "Monthly reset must be day 1")
        XCTAssertEqual(hour, 0)
        XCTAssertEqual(minute, 0)
        XCTAssertEqual(second, 0)

        // Must be in the future (or within a few seconds of now if we're
        // right at the month boundary).
        let tolerance: TimeInterval = 5
        XCTAssertGreaterThan(
            date.timeIntervalSinceNow,
            -tolerance,
            "Monthly reset must not be in the past"
        )
    }

    /// When `quota_reset_date_utc` is empty, the parser must still
    /// produce an `end_time` via the monthly-reset fallback so the
    /// countdown always renders.
    func testEmptyResetDateGetsMonthlyFallback() throws {
        let json = """
        {
          "copilot_plan": "pro",
          "quota_reset_date_utc": "",
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
        let endTime = response.rawData["premium_interactions:end_time"]
        XCTAssertNotNil(endTime, "Empty reset date must still produce end_time via fallback")
        if let ets = endTime, let ms = Int64(ets) {
            XCTAssertGreaterThan(ms, 0, "Fallback end_time must be > 0")
        }
    }

    /// When `quota_reset_date_utc` is completely absent from the JSON,
    /// the parser must still produce an `end_time` via the monthly
    /// fallback so the countdown always renders.
    func testMissingResetDateFieldGetsMonthlyFallback() throws {
        let json = """
        {
          "copilot_plan": "pro",
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
        let endTime = response.rawData["premium_interactions:end_time"]
        XCTAssertNotNil(endTime, "Missing reset_date field must still produce end_time via fallback")
        if let ets = endTime, let ms = Int64(ets) {
            XCTAssertGreaterThan(ms, 0, "Fallback end_time must be > 0")
        }
    }

    /// When `quota_reset_date_utc` is malformed, the parser falls back
    /// to `nextMonthlyResetMs()` so the live countdown always has a value.
    /// This locks the soft-fail + fallback behavior.
    func testMalformedResetDateFallsBackToMonthlyReset() throws {
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
        // `end_time` must now be present — fallback is `nextMonthlyResetMs()`.
        XCTAssertEqual(response.rawData["premium_interactions:reset_date"], "not a date")
        let endTime = response.rawData["premium_interactions:end_time"]
        XCTAssertNotNil(endTime, "Malformed reset date must still produce end_time via monthly fallback")
        if let ets = endTime, let ms = Int64(ets) {
            XCTAssertGreaterThan(ms, 0, "Fallback end_time must be > 0")
        }
    }
}
