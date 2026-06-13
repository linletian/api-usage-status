import XCTest
@testable import APIUsageStatus

final class WeeklyQuotaTests: XCTestCase {

    // MARK: - Happy paths

    func testActiveStatusBuildsLimitedQuota() {
        let response = makeResponse([
            "general:weekly_status": "1",
            "general:weekly_percent": "30.0",
            "general:weekly_remaining": "70.0"
        ])

        let quota = WeeklyQuota.from(response: response, dimension: "general")

        XCTAssertNotNil(quota)
        XCTAssertEqual(quota?.percent, 30.0)
        XCTAssertEqual(quota?.remaining, 70.0)
        XCTAssertEqual(quota?.isUnlimited, false)
    }

    func testInactiveStatusBuildsUnlimitedQuota() {
        // status 3 is what the live MiniMax API returns for plans without a weekly cap.
        let response = makeResponse([
            "general:weekly_status": "3",
            "general:weekly_percent": "0.0",
            "general:weekly_remaining": "100.0"
        ])

        let quota = WeeklyQuota.from(response: response, dimension: "general")

        XCTAssertNotNil(quota)
        XCTAssertEqual(quota?.isUnlimited, true)
        XCTAssertEqual(quota?.percent, 0.0)
        XCTAssertEqual(quota?.remaining, 100.0)
    }

    func testAnyNonOneStatusIsTreatedAsUnlimited() {
        // status 0 (uninitialized) and 2 (observed in other MiniMax responses) are not 1.
        for rawStatus in ["0", "2", "3", "9"] {
            let response = makeResponse([
                "general:weekly_status": rawStatus,
                "general:weekly_percent": "50.0",
                "general:weekly_remaining": "50.0"
            ])
            let quota = WeeklyQuota.from(response: response, dimension: "general")
            XCTAssertEqual(quota?.isUnlimited, true, "status=\(rawStatus) should be unlimited")
        }
    }

    func testDimensionIsolatesModels() {
        // Two models with the same status but different dimensions must not collide.
        let response = makeResponse([
            "general:weekly_status": "1",
            "general:weekly_percent": "20.0",
            "general:weekly_remaining": "80.0",
            "video:weekly_status": "1",
            "video:weekly_percent": "40.0",
            "video:weekly_remaining": "60.0"
        ])

        let general = WeeklyQuota.from(response: response, dimension: "general")
        let video = WeeklyQuota.from(response: response, dimension: "video")

        XCTAssertEqual(general?.percent, 20.0)
        XCTAssertEqual(video?.percent, 40.0)
    }

    // MARK: - Missing-field guard

    func testMissingStatusReturnsNil() {
        let response = makeResponse([
            "general:weekly_percent": "30.0",
            "general:weekly_remaining": "70.0"
        ])
        XCTAssertNil(WeeklyQuota.from(response: response, dimension: "general"))
    }

    func testMissingPercentReturnsNil() {
        let response = makeResponse([
            "general:weekly_status": "1",
            "general:weekly_remaining": "70.0"
        ])
        XCTAssertNil(WeeklyQuota.from(response: response, dimension: "general"))
    }

    func testMissingRemainingReturnsNil() {
        let response = makeResponse([
            "general:weekly_status": "1",
            "general:weekly_percent": "30.0"
        ])
        XCTAssertNil(WeeklyQuota.from(response: response, dimension: "general"))
    }

    func testMalformedStatusReturnsNil() {
        let response = makeResponse([
            "general:weekly_status": "not-a-number",
            "general:weekly_percent": "30.0",
            "general:weekly_remaining": "70.0"
        ])
        XCTAssertNil(WeeklyQuota.from(response: response, dimension: "general"))
    }

    func testEmptyResponseReturnsNil() {
        XCTAssertNil(WeeklyQuota.from(response: makeResponse([:]), dimension: "general"))
    }

    func testPercentWithPercentSignSuffix() {
        // parsePercent strips a trailing '%'. Realistic for callers that pre-format.
        let response = makeResponse([
            "general:weekly_status": "1",
            "general:weekly_percent": "30%",
            "general:weekly_remaining": "70%"
        ])
        let quota = WeeklyQuota.from(response: response, dimension: "general")
        XCTAssertEqual(quota?.percent, 30.0)
        XCTAssertEqual(quota?.remaining, 70.0)
    }

    // MARK: - Helpers

    private func makeResponse(_ rawData: [String: String]) -> SupplierResponse {
        SupplierResponse(rawData: rawData, currency: nil, isAvailable: true)
    }
}
