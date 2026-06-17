import XCTest
@testable import APIUsageStatus

/// Tests for MetricConfig persistence behaviour.
///
/// MetricConfig is the *persisted* (on-disk JSON) counterpart of MetricSnapshot.
/// It must round-trip through Codable without losing any field, and must
/// default `displayInMenuBar` to `true` so a freshly-decoded config behaves
/// identically to one the user has explicitly enabled for display.
final class MetricConfigCodableTests: XCTestCase {

    // MARK: - Codable round-trip

    func testEncodeDecodeRoundtripPreservesAllFields() throws {
        let original = MetricConfig(
            key: "minimax.general.5h",
            group: "minimax",
            window: "5h",
            displayInMenuBar: false
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MetricConfig.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.key, "minimax.general.5h")
        XCTAssertEqual(decoded.group, "minimax")
        XCTAssertEqual(decoded.window, "5h")
        XCTAssertFalse(decoded.displayInMenuBar)
    }

    func testEncodedJSONUsesSnakeCaseKeys() throws {
        let config = MetricConfig(
            key: "deepseek.balance",
            group: "deepseek",
            window: nil,
            displayInMenuBar: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(config)

        let jsonObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(jsonObject.keys),
            Set(["key", "group", "window", "display_in_menu_bar"]),
            "Encoded JSON must use the exact snake_case key set, no more, no less."
        )
        XCTAssertEqual(jsonObject["key"] as? String, "deepseek.balance")
        XCTAssertEqual(jsonObject["group"] as? String, "deepseek")
        XCTAssertNil(jsonObject["window"])
        XCTAssertEqual(jsonObject["display_in_menu_bar"] as? Bool, true)
    }

    func testDecodingOmittedGroupAndWindowLeavesThemNil() throws {
        // Only `key` is required; `group`, `window`, `display_in_menu_bar`
        // must all fall back to defaults when absent from the JSON.
        let json = #"{"key":"github.copilot.monthly"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MetricConfig.self, from: json)

        XCTAssertEqual(decoded.key, "github.copilot.monthly")
        XCTAssertNil(decoded.group)
        XCTAssertNil(decoded.window)
        XCTAssertTrue(decoded.displayInMenuBar)
    }

    // MARK: - Default values

    func testDefaultDisplayInMenuBarIsTrue() {
        // `displayInMenuBar` is the only non-optional Bool on MetricConfig.
        // It defaults to `true` so that newly-added metrics show up in the
        // menu bar without users having to opt-in for every metric.
        let config = MetricConfig(key: "opencode.5h", group: nil, window: nil)

        XCTAssertTrue(config.displayInMenuBar)
    }

    func testDefaultGroupIsNil() {
        let config = MetricConfig(key: "opencode.5h", group: nil, window: nil)

        XCTAssertNil(config.group)
    }

    func testDefaultWindowIsNil() {
        let config = MetricConfig(key: "opencode.5h", group: nil, window: nil)

        XCTAssertNil(config.window)
    }

    // MARK: - Equatable

    func testDifferentKeysAreNotEqual() {
        let a = MetricConfig(key: "minimax.general.5h")
        let b = MetricConfig(key: "minimax.general.weekly")

        XCTAssertNotEqual(a, b)
    }

    func testExplicitDefaultsAreEqualToImplicitDefaults() {
        // Defining all fields explicitly (group=nil, window=nil,
        // displayInMenuBar=true) must produce the same struct as one built
        // via the all-defaults initializer — this is what makes a default
        // config indistinguishable from one explicitly authored with defaults.
        let implicit = MetricConfig(key: "minimax.general.5h")
        let explicit = MetricConfig(
            key: "minimax.general.5h",
            group: nil,
            window: nil,
            displayInMenuBar: true
        )

        XCTAssertEqual(implicit, explicit)
    }
}
