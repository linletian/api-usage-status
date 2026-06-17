import Foundation

// MARK: - ColorMode

enum ColorMode: String, Codable, Equatable {
    case monochrome = "monochrome"
    case color = "color"

    static var defaultMode: ColorMode { .monochrome }
}

// MARK: - GlobalSettings

struct GlobalSettings: Codable, Equatable {
    var refreshIntervalMinutes: Int
    var colorMode: ColorMode
    var launchAtLogin: Bool
    var notificationsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case refreshIntervalMinutes = "refresh_interval_minutes"
        case colorMode = "color_mode"
        case launchAtLogin = "launch_at_login"
        case notificationsEnabled = "notifications_enabled"
    }

    init(
        refreshIntervalMinutes: Int = 5,
        colorMode: ColorMode = ColorMode.defaultMode,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = true
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.colorMode = colorMode
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
    }

    static var `default`: GlobalSettings {
        GlobalSettings()
    }
}

// MARK: - InstancesContainer

/// The top-level JSON structure for instances.json
struct InstancesContainer: Codable {
    /// Bumped whenever the on-disk shape changes. Use `needsMigration`
    /// (or `PersistenceService`) to detect out-of-date files.
    var schemaVersion: Int = InstancesContainer.currentSchemaVersion
    var instances: [Instance]
    var settings: GlobalSettings

    static let currentSchemaVersion: Int = 2

    /// True when the decoded container is older than the bundled version.
    /// Task 10 wires the actual migration routine; this just detects.
    var needsMigration: Bool {
        schemaVersion < InstancesContainer.currentSchemaVersion
    }

    init(
        instances: [Instance] = [],
        settings: GlobalSettings = .default,
        schemaVersion: Int = InstancesContainer.currentSchemaVersion
    ) {
        self.instances = instances
        self.settings = settings
        self.schemaVersion = schemaVersion
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case instances
        case settings
    }
}