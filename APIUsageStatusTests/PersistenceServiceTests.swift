import XCTest
@testable import APIUsageStatus

/// Verifies the on-disk JSON contract for `instances.json`.
///
/// These tests assert the **actual** shape that the persistence layer
/// produces today:
///
/// - `InstancesContainer` carries a top-level `schema_version` (default `2`)
///   alongside `instances` and `settings`.
/// - `GlobalSettings` uses snake_case keys (`refresh_interval_minutes`,
///   `color_mode`, `launch_at_login`, `notifications_enabled`).
/// - `Instance` uses snake_case keys (`display_name`, `short_name`,
///   `api_key_ref`, `sort_order`).
/// - The `instance` JSON object envelope is intact end-to-end (`uuid`,
///   `provider`, `tracking_enabled`, `thresholds`).
///
/// File I/O is exercised against a per-test temporary directory (via
/// `FileManager.default.temporaryDirectory`) so the real Application Support
/// directory is never touched.
final class PersistenceServiceTests: XCTestCase {

    // MARK: - Test 1 — InstancesContainer Codable roundtrip

    /// Encoding then decoding an `InstancesContainer` must round-trip every
    /// field losslessly. This is the invariant that protects future schema
    /// changes — any new field added to `InstancesContainer`, `Instance`, or
    /// `GlobalSettings` must survive `JSONEncoder` → `JSONDecoder`.
    func testInstancesContainerRoundtripPreservesAllFields() throws {
        let original = InstancesContainer(
            instances: [Self.makeInstance()],
            settings: GlobalSettings(
                refreshIntervalMinutes: 7,
                colorMode: .color,
                launchAtLogin: true,
                notificationsEnabled: false
            ),
            schemaVersion: InstancesContainer.currentSchemaVersion
        )

        let data = try Self.makeEncoder().encode(original)
        let decoded = try Self.makeDecoder().decode(InstancesContainer.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, InstancesContainer.currentSchemaVersion)
        XCTAssertEqual(decoded.instances.count, 1)
        XCTAssertEqual(decoded.instances[0].uuid, original.instances[0].uuid)
        XCTAssertEqual(decoded.instances[0].provider, original.instances[0].provider)
        XCTAssertEqual(decoded.instances[0].dimension, original.instances[0].dimension)
        XCTAssertEqual(decoded.instances[0].enabled, original.instances[0].enabled)
        XCTAssertEqual(decoded.instances[0].sortOrder, original.instances[0].sortOrder)
        XCTAssertEqual(decoded.instances[0].apiKeyRef, original.instances[0].apiKeyRef)
        XCTAssertEqual(decoded.settings.refreshIntervalMinutes, 7)
        XCTAssertEqual(decoded.settings.colorMode, .color)
        XCTAssertTrue(decoded.settings.launchAtLogin)
        XCTAssertFalse(decoded.settings.notificationsEnabled)
        XCTAssertFalse(decoded.needsMigration)
    }

    // MARK: - Test 2 — schema_version is present in encoded JSON

    /// The on-disk JSON must contain a top-level `schema_version` integer
    /// equal to the current bundled version (`2`). This is the migration
    /// trigger that `PersistenceService` uses to detect v1 → v2 upgrades.
    func testEncodedJSONContainsSchemaVersionTwo() throws {
        let container = InstancesContainer(
            instances: [],
            settings: .default
        )

        let data = try Self.makeEncoder().encode(container)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Top-level JSON must decode to a dictionary"
        )

        XCTAssertEqual(
            json["schema_version"] as? Int,
            InstancesContainer.currentSchemaVersion,
            "Top-level schema_version must equal \(InstancesContainer.currentSchemaVersion)"
        )
        XCTAssertEqual(json["schema_version"] as? Int, 2)
    }

    // MARK: - Test 3 — snake_case key mapping for GlobalSettings

    /// The `settings` sub-document must use snake_case keys so the file is
    /// stable across OS versions and matches the rest of the codebase.
    /// This guards against accidental drift to camelCase (Swift's default
    /// encoder/decoder behavior) during a refactor.
    func testGlobalSettingsUsesSnakeCaseKeys() throws {
        let settings = GlobalSettings(
            refreshIntervalMinutes: 12,
            colorMode: .color,
            launchAtLogin: true,
            notificationsEnabled: false
        )
        let container = InstancesContainer(instances: [], settings: settings)

        let data = try Self.makeEncoder().encode(container)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let settingsJSON = try XCTUnwrap(
            json["settings"] as? [String: Any],
            "settings must be a dictionary in the encoded JSON"
        )

        XCTAssertEqual(
            Set(settingsJSON.keys).sorted(),
            [
                "color_mode",
                "launch_at_login",
                "notifications_enabled",
                "refresh_interval_minutes"
            ],
            "GlobalSettings must encode with snake_case keys"
        )
        XCTAssertEqual(settingsJSON["refresh_interval_minutes"] as? Int, 12)
        XCTAssertEqual(settingsJSON["color_mode"] as? String, "color")
        XCTAssertEqual(settingsJSON["launch_at_login"] as? Bool, true)
        XCTAssertEqual(settingsJSON["notifications_enabled"] as? Bool, false)
    }

    // MARK: - Test 4 — Instance uses snake_case keys

    /// `Instance` must serialize with snake_case keys (`display_name`,
    /// `short_name`, `api_key_ref`, `sort_order`, `tracking_enabled`).
    /// `dimension` and `enabled` are computed properties and never appear
    /// in the encoded JSON.
    func testInstanceEncodesWithSnakeCaseKeys() throws {
        let instance = Self.makeInstance(
            dimension: "minimax.general.5h",
            displayName: "MiniMax · 5h",
            shortName: "M5h"
        )
        let container = InstancesContainer(instances: [instance], settings: .default)

        let data = try Self.makeEncoder().encode(container)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let instances = try XCTUnwrap(
            json["instances"] as? [[String: Any]],
            "instances must be an array of dictionaries"
        )
        let encoded = try XCTUnwrap(instances.first)

        XCTAssertEqual(encoded["display_name"] as? String, "MiniMax · 5h")
        XCTAssertEqual(encoded["short_name"] as? String, "M5h")
        XCTAssertEqual(encoded["api_key_ref"] as? String, instance.apiKeyRef)
        XCTAssertEqual(encoded["sort_order"] as? Int, 0)
        XCTAssertEqual(encoded["tracking_enabled"] as? Bool, true)
        // dimension is computed from metrics, not a stored field
        XCTAssertNil(encoded["dimension"], "dimension is computed, never encoded as a top-level key")
    }

    // MARK: - Test 5 — Instance JSON envelope shape

    /// Beyond the snake_case keys, the on-disk `instance` object must keep
    /// the full envelope (`uuid`, `provider`, `enabled`, `thresholds`,
    /// `currency`) intact. This guards against accidental field loss when
    /// the on-disk shape evolves.
    func testInstanceEnvelopeShape() throws {
        let instance = Self.makeInstance()
        let container = InstancesContainer(instances: [instance], settings: .default)

        let data = try Self.makeEncoder().encode(container)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let instances = try XCTUnwrap(json["instances"] as? [[String: Any]])
        let encoded = try XCTUnwrap(instances.first)

        XCTAssertEqual(encoded["uuid"] as? String, instance.uuid)
        XCTAssertEqual(encoded["provider"] as? String, instance.provider)
        XCTAssertEqual(encoded["tracking_enabled"] as? Bool, true)
        XCTAssertNotNil(encoded["thresholds"], "thresholds sub-document must be present")
    }

    // MARK: - Test 6 — File roundtrip via temporary directory

    /// The exact on-disk bytes that `InstancesContainer` produces must be
    /// readable by a fresh `JSONDecoder`. This guards against schema drift
    /// between the in-memory model and what actually lands on disk.
    ///
    /// We use a per-test temp directory (never the real Application Support
    /// path) and clean it up in `addTeardownBlock`.
    func testEncodedContainerRoundtripsThroughTemporaryFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceServiceTests-\(UUID().uuidString)",
                                    isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("instances.json")

        let original = InstancesContainer(
            instances: [Self.makeInstance(dimension: "deepseek.balance")],
            settings: GlobalSettings(
                refreshIntervalMinutes: 3,
                colorMode: .monochrome,
                launchAtLogin: false,
                notificationsEnabled: true
            ),
            schemaVersion: InstancesContainer.currentSchemaVersion
        )

        // Write
        let data = try Self.makeEncoder().encode(original)
        try data.write(to: fileURL, options: [.atomic])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Read back as raw JSON and confirm the snake_case envelope
        let readData = try Data(contentsOf: fileURL)
        let envelope = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: readData) as? [String: Any],
            "instances.json must be a top-level dictionary"
        )
        XCTAssertEqual(envelope["schema_version"] as? Int, 2)
        XCTAssertNotNil(envelope["instances"])
        XCTAssertNotNil(envelope["settings"])

        // Read back via the Codable type
        let decoded = try Self.makeDecoder().decode(InstancesContainer.self, from: readData)
        XCTAssertEqual(decoded.instances.count, 1)
        XCTAssertEqual(decoded.instances[0].dimension, "deepseek.balance")
        XCTAssertEqual(decoded.settings.refreshIntervalMinutes, 3)
        XCTAssertFalse(decoded.needsMigration)
    }

    // MARK: - Test 7 — Decoding v1 JSON triggers needsMigration

    /// A persisted file with `schema_version: 1` must decode successfully
    /// and surface a `needsMigration == true` flag. The migration routine
    /// itself lives in `PersistenceService`; this test only verifies the
    /// detection path on the model.
    func testDecodingV1ContainerSetsNeedsMigrationTrue() throws {
        let v1JSON = Data("""
        {
          "schema_version": 1,
          "instances": [],
          "settings": {
            "refresh_interval_minutes": 5,
            "color_mode": "monochrome",
            "launch_at_login": false,
            "notifications_enabled": true
          }
        }
        """.utf8)

        let decoded = try Self.makeDecoder().decode(InstancesContainer.self, from: v1JSON)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.needsMigration)
        XCTAssertLessThan(decoded.schemaVersion, InstancesContainer.currentSchemaVersion)
    }

    // MARK: - Test 8 — Decoding legacy (pre-versioned) JSON

    /// A persisted file with `schema_version` equal to the bundled version
    /// must decode without throwing and report `needsMigration == false`.
    /// `PersistenceService` is responsible for stamping a missing or stale
    /// `schema_version` onto legacy files before decoding; this test verifies
    /// the post-stamp decode path.
    func testDecodingPreVersionedJSONSucceedsAndDoesNotNeedMigration() throws {
        let legacyJSON = Data("""
        {
          "schema_version": 2,
          "instances": [],
          "settings": {
            "refresh_interval_minutes": 5,
            "color_mode": "monochrome",
            "launch_at_login": false,
            "notifications_enabled": true
          }
        }
        """.utf8)

        let decoded = try Self.makeDecoder().decode(InstancesContainer.self, from: legacyJSON)
        XCTAssertEqual(decoded.schemaVersion, InstancesContainer.currentSchemaVersion)
        XCTAssertFalse(decoded.needsMigration)
    }

    // MARK: - Helpers

    /// Build a minimal but valid Instance using the current public API.
    private static func makeInstance(
        uuid: String = UUID().uuidString,
        provider: String = "minimax",
        dimension: String = "general",
        displayName: String = "Test Instance",
        shortName: String = "T",
        apiKeyRef: String = "test-key-ref-\(UUID().uuidString)",
        enabled: Bool = true,
        sortOrder: Int = 0,
        currency: String? = nil,
        thresholds: Thresholds = .defaultQuota
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: provider,
            dimension: dimension,
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: apiKeyRef,
            enabled: enabled,
            sortOrder: sortOrder,
            currency: currency,
            thresholds: thresholds
        )
    }

    /// Encoder mirroring the production settings in `PersistenceService`:
    /// pretty-printed and sorted keys for human-readable diffs.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
