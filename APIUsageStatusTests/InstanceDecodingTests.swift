import XCTest
@testable import APIUsageStatus

final class InstanceDecodingTests: XCTestCase {

    // MARK: - Old format (dimension string, no metrics)

    /// Old format JSON with a bare `dimension` string and no metrics array
    /// now produces empty metrics (dimension is no longer decoded).
    func testDecodeOldFormatWithoutMetricsProducesEmptyMetrics() throws {
        let json = """
        {
          "uuid": "550e8400-e29b-41d4-a716-446655440000",
          "provider": "minimax",
          "dimension": "5h",
          "display_name": "MiniMax General",
          "short_name": "MM",
          "api_key_ref": "key-minimax",
          "tracking_enabled": true,
          "sort_order": 0,
          "currency": "USD",
          "thresholds": { "quota": { "warning": 80, "critical": 95 } }
        }
        """.data(using: .utf8)!

        let instance = try JSONDecoder().decode(Instance.self, from: json)

        XCTAssertEqual(instance.dimension, "")
        XCTAssertEqual(instance.metrics.count, 0)
        XCTAssertEqual(instance.trackingEnabled, true)
    }

    // MARK: - New format (metrics array)

    func testDecodeNewFormatMetricsArrayPreservesGroupAndWindow() throws {
        let json = """
        {
          "uuid": "550e8400-e29b-41d4-a716-446655440000",
          "provider": "minimax",
          "display_name": "MiniMax General",
          "short_name": "MM",
          "api_key_ref": "key-minimax",
          "tracking_enabled": true,
          "sort_order": 0,
          "thresholds": { "quota": { "warning": 80, "critical": 95 } },
          "metrics": [
            { "key": "general:5h", "group": "general", "window": "5h", "display_in_menu_bar": true },
            { "key": "general:weekly", "group": "general", "window": "weekly", "display_in_menu_bar": false }
          ]
        }
        """.data(using: .utf8)!

        let instance = try JSONDecoder().decode(Instance.self, from: json)

        XCTAssertEqual(instance.metrics.count, 2)
        XCTAssertEqual(instance.metrics[0].key, "general:5h")
        XCTAssertEqual(instance.metrics[0].group, "general")
        XCTAssertEqual(instance.metrics[0].window, "5h")
        XCTAssertTrue(instance.metrics[0].displayInMenuBar)
        XCTAssertEqual(instance.metrics[1].key, "general:weekly")
        XCTAssertEqual(instance.metrics[1].group, "general")
        XCTAssertEqual(instance.metrics[1].window, "weekly")
        XCTAssertFalse(instance.metrics[1].displayInMenuBar)
        // dimension is computed from metrics.first?.key
        XCTAssertEqual(instance.dimension, "general:5h")
    }

    // MARK: - Missing both metrics and dimension

    func testDecodeMissingMetricsAndDimensionProducesEmptyArray() throws {
        let json = """
        {
          "uuid": "550e8400-e29b-41d4-a716-446655440000",
          "provider": "opencode",
          "display_name": "OpenCode",
          "short_name": "OC",
          "api_key_ref": "key-oc",
          "tracking_enabled": true,
          "sort_order": 1,
          "thresholds": { "quota": { "warning": 80, "critical": 95 } }
        }
        """.data(using: .utf8)!

        let instance = try JSONDecoder().decode(Instance.self, from: json)

        XCTAssertEqual(instance.metrics.count, 0)
        XCTAssertEqual(instance.dimension, "")
        XCTAssertEqual(instance.trackingEnabled, true)
    }

    // MARK: - All existing fields still decode correctly

    func testDecodePreservesAllExistingInstanceFields() throws {
        let json = """
        {
          "uuid": "550e8400-e29b-41d4-a716-446655440000",
          "provider": "deepseek",
          "dimension": "balance",
          "display_name": "DeepSeek",
          "short_name": "DS",
          "api_key_ref": "key-ds",
          "tracking_enabled": false,
          "sort_order": 2,
          "currency": "CNY",
          "thresholds": { "balance": { "increase": 50, "decrease": 10 } },
          "metrics": [
            { "key": "deepseek.balance", "window": null, "group": null, "display_in_menu_bar": true }
          ]
        }
        """.data(using: .utf8)!

        let instance = try JSONDecoder().decode(Instance.self, from: json)

        XCTAssertEqual(instance.uuid, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(instance.provider, "deepseek")
        // dimension is computed from metrics.first?.key (the legacy "dimension": "balance" key is ignored)
        XCTAssertEqual(instance.dimension, "deepseek.balance")
        XCTAssertEqual(instance.displayName, "DeepSeek")
        XCTAssertEqual(instance.shortName, "DS")
        XCTAssertEqual(instance.apiKeyRef, "key-ds")
        XCTAssertEqual(instance.trackingEnabled, false)
        XCTAssertEqual(instance.enabled, false)
        XCTAssertEqual(instance.sortOrder, 2)
        XCTAssertEqual(instance.currency, "CNY")
        XCTAssertEqual(instance.metrics.count, 1)
        XCTAssertEqual(instance.metrics[0].key, "deepseek.balance")
    }

    // MARK: - New format without dimension key

    func testDecodeNewFormatWithoutDimensionKeySetsDimensionFromFirstMetric() throws {
        let json = """
        {
          "uuid": "550e8400-e29b-41d4-a716-446655440000",
          "provider": "minimax",
          "display_name": "MiniMax Video",
          "short_name": "MV",
          "api_key_ref": "key-mv",
          "tracking_enabled": true,
          "sort_order": 3,
          "thresholds": { "quota": { "warning": 80, "critical": 95 } },
          "metrics": [
            { "key": "video:5h", "group": "video", "window": "5h", "display_in_menu_bar": true }
          ]
        }
        """.data(using: .utf8)!

        let instance = try JSONDecoder().decode(Instance.self, from: json)

        XCTAssertEqual(instance.metrics.count, 1)
        XCTAssertEqual(instance.metrics[0].key, "video:5h")
        XCTAssertEqual(instance.dimension, "video:5h")
    }
}
