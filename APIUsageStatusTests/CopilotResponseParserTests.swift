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
}
