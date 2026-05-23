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
    var instances: [Instance]
    var settings: GlobalSettings

    init(instances: [Instance] = [], settings: GlobalSettings = .default) {
        self.instances = instances
        self.settings = settings
    }
}