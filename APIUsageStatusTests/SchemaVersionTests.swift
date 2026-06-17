import XCTest
@testable import APIUsageStatus

final class SchemaVersionTests: XCTestCase {

    // MARK: - InstancesContainer schemaVersion property

    func testNewInstancesContainerEncodesSchemaVersionTwo() throws {
        let container = InstancesContainer(
            instances: [],
            settings: .default
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(container)

        // Parse the resulting JSON and confirm schema_version == 2
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 2)
    }

    func testNewInstancesContainerDecodesSchemaVersionTwo() throws {
        let json = """
        {
          "instances": [],
          "settings": {
            "refresh_interval_minutes": 5,
            "color_mode": "monochrome",
            "launch_at_login": false,
            "notifications_enabled": true
          },
          "schema_version": 2
        }
        """.data(using: .utf8)!

        let container = try JSONDecoder().decode(InstancesContainer.self, from: json)
        XCTAssertEqual(container.schemaVersion, 2)
    }

    // MARK: - Migration detection

    func testOldSchemaVersionOneIsDetectedAsNeedingMigration() throws {
        let json = """
        {
          "instances": [],
          "settings": {
            "refresh_interval_minutes": 5,
            "color_mode": "monochrome",
            "launch_at_login": false,
            "notifications_enabled": true
          },
          "schema_version": 1
        }
        """.data(using: .utf8)!

        let container = try JSONDecoder().decode(InstancesContainer.self, from: json)
        XCTAssertEqual(container.schemaVersion, 1)
        XCTAssertTrue(container.needsMigration)
    }

    func testCurrentSchemaVersionDoesNotNeedMigration() {
        let container = InstancesContainer()
        XCTAssertEqual(container.schemaVersion, 2)
        XCTAssertFalse(container.needsMigration)
    }


}
