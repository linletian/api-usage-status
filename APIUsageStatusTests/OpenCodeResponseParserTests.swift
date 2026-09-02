import XCTest
@testable import APIUsageStatus

final class OpenCodeResponseParserTests: XCTestCase {
    let parser = OpenCodeResponseParser()

    // Fixture captured 2026-09-02 from the live
    // `GET https://opencode.ai/zen/go/v1/usage` (PR #16513, post-simplification
    // response shape).
    private let realAPIJSON = """
    {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-02T19:44:30.306Z"},"weekly":{"status":"ok","percent":79,"resetsAt":"2026-09-07T00:00:00.306Z"},"monthly":{"status":"ok","percent":55,"resetsAt":"2026-09-25T11:33:14.306Z"}}}
    """.data(using: .utf8)!

    func testParseRealFixture() throws {
        let p = try parser.parse(realAPIJSON)

        XCTAssertEqual(p.fiveHour.percent, 0)
        // 2026-09-02T19:44:30.306Z — ±1ms tolerance for the Double ms
        // truncation in the parser.
        XCTAssertEqual(Double(p.fiveHour.endTimeMs), 1_788_378_270_306, accuracy: 1)

        XCTAssertEqual(p.weekly.percent, 79)
        XCTAssertEqual(Double(p.weekly.endTimeMs), 1_788_739_200_306, accuracy: 1)

        XCTAssertEqual(p.monthly.percent, 55)
        XCTAssertEqual(Double(p.monthly.endTimeMs), 1_790_335_994_306, accuracy: 1)
    }

    func testParseRateLimitedWindow() throws {
        let json = """
        {"usage":{"rolling":{"status":"rate-limited","percent":100,"resetsAt":"2026-09-02T19:44:30.306Z"},"weekly":{"status":"ok","percent":3,"resetsAt":"2026-09-07T00:00:00.306Z"},"monthly":{"status":"ok","percent":7,"resetsAt":"2026-09-25T11:33:14.306Z"}}}
        """.data(using: .utf8)!
        let p = try parser.parse(json)
        XCTAssertEqual(p.fiveHour.percent, 100)
        XCTAssertEqual(p.weekly.percent, 3)
        XCTAssertEqual(p.monthly.percent, 7)
    }

    func testParseClampsOutOfRangePercent() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":150,"resetsAt":"2026-09-02T19:44:30.306Z"},"weekly":{"status":"ok","percent":-5,"resetsAt":"2026-09-07T00:00:00.306Z"},"monthly":{"status":"ok","percent":50,"resetsAt":"2026-09-25T11:33:14.306Z"}}}
        """.data(using: .utf8)!
        let p = try parser.parse(json)
        XCTAssertEqual(p.fiveHour.percent, 100)
        XCTAssertEqual(p.weekly.percent, 0)
    }

    func testParseRejectsMissingUsageKey() {
        let json = #"{"unexpected": true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try parser.parse(json))
    }

    func testParseRejectsNonObjectRoot() {
        let json = #"[1, 2, 3]"#.data(using: .utf8)!
        XCTAssertThrowsError(try parser.parse(json))
    }

    func testParseRejectsMissingWindow() {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"2026-09-02T19:44:30.306Z"},"weekly":{"status":"ok","percent":79,"resetsAt":"2026-09-07T00:00:00.306Z"}}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try parser.parse(json))
    }

    func testParseRejectsMissingPercent() {
        let json = """
        {"usage":{"rolling":{"status":"ok","resetsAt":"2026-09-02T19:44:30.306Z"},"weekly":{"status":"ok","percent":79,"resetsAt":"2026-09-07T00:00:00.306Z"},"monthly":{"status":"ok","percent":55,"resetsAt":"2026-09-25T11:33:14.306Z"}}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try parser.parse(json))
    }

    func testParseRejectsMalformedResetsAt() {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":0,"resetsAt":"not-a-date"},"weekly":{"status":"ok","percent":79,"resetsAt":"2026-09-07T00:00:00.306Z"},"monthly":{"status":"ok","percent":55,"resetsAt":"2026-09-25T11:33:14.306Z"}}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try parser.parse(json))
    }

    // MARK: - makeResponse (rawData shape)

    func testMakeResponseShape() {
        let parsed = OpenCodeResponseParser.Parsed(
            fiveHour: OpenCodeResponseParser.ParsedWindow(percent: 70.8, endTimeMs: 1_788_378_270_306),
            weekly: OpenCodeResponseParser.ParsedWindow(percent: 50, endTimeMs: 1_788_739_200_306),
            monthly: OpenCodeResponseParser.ParsedWindow(percent: 58.3, endTimeMs: 1_790_335_994_306)
        )
        let response = OpenCodeSupplier.makeResponse(from: parsed)

        XCTAssertEqual(response.rawData["5h"], "70.8")
        XCTAssertEqual(response.rawData["5h:end_time"], "1788378270306")
        XCTAssertEqual(response.rawData["weekly"], "50.0")
        XCTAssertEqual(response.rawData["weekly:end_time"], "1788739200306")
        XCTAssertEqual(response.rawData["monthly"], "58.3")
        XCTAssertEqual(response.rawData["monthly:end_time"], "1790335994306")

        // The API reports no absolute dollar amounts — the retired
        // local-SQLite path's keys must not come back.
        XCTAssertNil(response.rawData["5h:used"])
        XCTAssertNil(response.rawData["5h:limit"])
        XCTAssertNil(response.rawData["weekly:used"])
        XCTAssertNil(response.rawData["weekly:limit"])
        XCTAssertNil(response.rawData["monthly:used"])
        XCTAssertNil(response.rawData["monthly:limit"])

        XCTAssertNil(response.currency)
        XCTAssertTrue(response.isAvailable)
    }
}
