import XCTest
@testable import APIUsageStatus

final class DeepSeekResponseParserTests: XCTestCase {

    private let parser = DeepSeekResponseParser()

    func testSuccessfulParseCNY() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "USD", "total_balance": "50.00", "granted_balance": "5.00", "topped_up_balance": "45.00" },
            { "currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00" }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.currency, "CNY")
        XCTAssertEqual(response.rawData["balance"], "100.00")
        XCTAssertEqual(response.rawData["total_balance"], "110.00")
        XCTAssertEqual(response.rawData["granted_balance"], "10.00")
    }

    func testSuccessfulParseNoCNY() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "USD", "total_balance": "50.00", "granted_balance": "5.00", "topped_up_balance": "45.00" }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.currency, "USD")
        XCTAssertEqual(response.rawData["balance"], "45.00")
    }

    func testIsAvailableFalse() throws {
        let json = """
        {
          "is_available": false,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "10.00", "granted_balance": "0", "topped_up_balance": "10.00" }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertFalse(response.isAvailable)
        XCTAssertEqual(response.currency, "CNY")
        XCTAssertEqual(response.rawData["balance"], "10.00")
    }

    func testInvalidJSON() {
        let json = "not json".data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard let refreshError = error as? RefreshError else {
                XCTFail("Expected RefreshError")
                return
            }
            switch refreshError {
            case .parsingError:
                break
            default:
                XCTFail("Expected parsingError")
            }
        }
    }

    func testMissingBalanceInfos() {
        let json = """
        { "is_available": true }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard let refreshError = error as? RefreshError else {
                XCTFail("Expected RefreshError")
                return
            }
            switch refreshError {
            case .parsingError:
                break
            default:
                XCTFail("Expected parsingError")
            }
        }
    }

    func testEmptyBalanceInfos() {
        let json = """
        { "is_available": true, "balance_infos": [] }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard let refreshError = error as? RefreshError else {
                XCTFail("Expected RefreshError")
                return
            }
            switch refreshError {
            case .parsingError:
                break
            default:
                XCTFail("Expected parsingError")
            }
        }
    }

    func testMultipleCurrenciesCNYFirst() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": "80.00", "granted_balance": "5.00", "topped_up_balance": "75.00" },
            { "currency": "USD", "total_balance": "50.00", "granted_balance": "5.00", "topped_up_balance": "45.00" }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.currency, "CNY")
        XCTAssertEqual(response.rawData["balance"], "75.00")
        XCTAssertEqual(response.rawData["total_balance"], "80.00")
    }

    func testNumericBalanceValues() throws {
        let json = """
        {
          "is_available": true,
          "balance_infos": [
            { "currency": "CNY", "total_balance": 110, "granted_balance": 10, "topped_up_balance": 100 }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["balance"], "100")
        XCTAssertEqual(response.rawData["total_balance"], "110")
        XCTAssertEqual(response.rawData["granted_balance"], "10")
    }
}
