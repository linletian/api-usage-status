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
              "model_name": "MiniMax-M2.7",
              "current_interval_total_count": 600,
              "current_interval_usage_count": 57,
              "start_time": 1779174000000,
              "end_time": 1779192000000,
              "remains_time": 5024998,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "weekly_start_time": 1779033600000,
              "weekly_end_time": 1779638400000,
              "weekly_remains_time": 451424998
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.rawData["MiniMax-M2.7"], "9.5")
        XCTAssertEqual(response.rawData["MiniMax-M2.7:total"], "600")
        XCTAssertEqual(response.rawData["MiniMax-M2.7:used"], "57")
        XCTAssertEqual(response.rawData["_model_names"], "MiniMax-M2.7")
    }

    func testMultipleModels() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "Model-A",
              "current_interval_total_count": 100,
              "current_interval_usage_count": 25,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            },
            {
              "model_name": "Model-B",
              "current_interval_total_count": 200,
              "current_interval_usage_count": 80,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["Model-A"], "25.0")
        XCTAssertEqual(response.rawData["Model-B"], "40.0")
        XCTAssertEqual(response.rawData["Model-A:total"], "100")
        XCTAssertEqual(response.rawData["Model-B:total"], "200")
        XCTAssertEqual(response.rawData["_model_names"], "Model-A,Model-B")
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

    func testZeroQuotaModel() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "NoLimit-Model",
              "current_interval_total_count": 0,
              "current_interval_usage_count": 42,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData["NoLimit-Model"], "NO_LIMIT")
        XCTAssertEqual(response.rawData["NoLimit-Model:total"], "0")
        XCTAssertEqual(response.rawData["NoLimit-Model:used"], "42")
    }

    func testMissingModelName() throws {
        let json = """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "current_interval_total_count": 100,
              "current_interval_usage_count": 50,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            },
            {
              "model_name": "Valid-Model",
              "current_interval_total_count": 200,
              "current_interval_usage_count": 60,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try parser.parse(json)

        XCTAssertEqual(response.rawData.count, 6)
        XCTAssertEqual(response.rawData["Valid-Model"], "30.0")
        XCTAssertEqual(response.rawData["_model_names"], "Valid-Model")
    }
}
