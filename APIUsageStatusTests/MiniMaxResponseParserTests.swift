import XCTest
@testable import APIUsageStatus

final class MiniMaxResponseParserTests: XCTestCase {

    private let parser = MiniMaxResponseParser()

    func testSuccessfulParse() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 28,
              "start_time": 1781247600000,
              "end_time": 1781265600000,
              "remains_time": 5024998,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100,
              "weekly_start_time": 1780848000000,
              "weekly_end_time": 1781452800000,
              "weekly_remains_time": 451424998
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.rawData["general"], "72.0")
        XCTAssertEqual(response.rawData["general:status"], "1")
        XCTAssertEqual(response.rawData["general:remaining"], "28.0")
        XCTAssertEqual(response.rawData["general:weekly_status"], "3")
        XCTAssertEqual(response.rawData["general:weekly_remaining"], "100.0")
        XCTAssertEqual(response.rawData["general:weekly_percent"], "0.0")
        XCTAssertEqual(response.rawData["general:end_time"], "1781265600000")
        XCTAssertEqual(response.rawData["_model_names"], "general")
    }

    func testMultipleModels() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "Model-A",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 75,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 20
            },
            {
              "model_name": "Model-B",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 60,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 50
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["Model-A"], "25.0")
        XCTAssertEqual(response.rawData["Model-B"], "40.0")
        XCTAssertEqual(response.rawData["Model-A:weekly_percent"], "80.0")
        XCTAssertEqual(response.rawData["Model-B:weekly_percent"], "50.0")
        XCTAssertEqual(response.rawData["_model_names"], "Model-A,Model-B")
    }

    func testInactiveIntervalReportsZero() throws {
        // status 3 = interval not active. Should report 0% even if remaining_percent is non-zero.
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "video",
              "current_interval_status": 3,
              "current_interval_remaining_percent": 100,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 100
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["video"], "0.0")
        XCTAssertEqual(response.rawData["video:status"], "3")
        XCTAssertEqual(response.rawData["video:weekly_percent"], "0.0")
    }

    func testFullyConsumedInterval() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 0,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["general"], "100.0")
        XCTAssertEqual(response.rawData["general:weekly_percent"], "100.0")
    }

    func testExhaustedWithNonOneStatus() throws {
        // Regression test: when the 5h window is fully consumed, the
        // API may return status != 1 (e.g. 3) alongside remaining=0.
        // Parser must still report 100% — only fall back to 0% when
        // the percent field is entirely missing. Same logic applies
        // to the weekly window.
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_status": 3,
              "current_interval_remaining_percent": 0,
              "current_weekly_status": 3,
              "current_weekly_remaining_percent": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["general"], "100.0")
        XCTAssertEqual(response.rawData["general:status"], "3")
        XCTAssertEqual(response.rawData["general:weekly_percent"], "100.0")
    }

    func testFullyUnusedInterval() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 100,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 100
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["general"], "0.0")
        XCTAssertEqual(response.rawData["general:weekly_percent"], "0.0")
    }

    func testMissingModelRemains() {
        let json = """
        { "base_resp": { "status_code": 0, "status_msg": "success" } }
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

    func testInvalidJSON() {
        let json = "not valid json".data(using: .utf8)!

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

    func testAuthError() {
        let json = """
        {
          "base_resp": { "status_code": 1004, "status_msg": "unauthorized" },
          "model_remains": []
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard let refreshError = error as? RefreshError else {
                XCTFail("Expected RefreshError")
                return
            }
            switch refreshError {
            case .httpError(let statusCode):
                XCTAssertEqual(statusCode, 401)
            default:
                XCTFail("Expected httpError(401)")
            }
        }
    }

    func testAPIBusinessError() {
        let json = """
        {
          "base_resp": { "status_code": 500, "status_msg": "Internal Error" },
          "model_remains": []
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try parser.parse(json)) { error in
            guard let refreshError = error as? RefreshError else {
                XCTFail("Expected RefreshError")
                return
            }
            switch refreshError {
            case .parsingError(let msg):
                XCTAssertTrue(msg.contains("500"))
            default:
                XCTFail("Expected parsingError")
            }
        }
    }

    func testMissingModelName() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "current_interval_status": 1,
              "current_interval_remaining_percent": 50,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 100
            },
            {
              "model_name": "Valid-Model",
              "current_interval_status": 1,
              "current_interval_remaining_percent": 70,
              "current_weekly_status": 1,
              "current_weekly_remaining_percent": 100
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        // Only the entry with a model_name is parsed.
        XCTAssertEqual(response.rawData["Valid-Model"], "30.0")
        XCTAssertEqual(response.rawData["_model_names"], "Valid-Model")
    }
}
