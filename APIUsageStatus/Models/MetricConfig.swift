import Foundation

// MARK: - MetricConfig

/// Persisted configuration for a single metric (a `(provider, group, window)`
/// triple such as `minimax.general.5h` or `deepseek.balance`).
///
/// `MetricConfig` is the *only* field shape that survives across app launches —
/// it is serialized into the instances.json file via `PersistenceService`.
/// Runtime values (percent, displayed usage/limit, color state, remaining
/// cycle time) are intentionally **not** fields on this struct; those live
/// exclusively on `MetricSnapshot`, which is never persisted.
///
/// JSON keys use snake_case to match the rest of `instances.json`
/// (e.g. `display_in_menu_bar`, `refresh_interval_minutes`).
struct MetricConfig: Codable, Equatable {
    /// Stable lookup key. Format: `"{provider}.{group}.{window}"` for quota
    /// metrics, or `"{provider}.balance"` for balance metrics.
    let key: String

    /// Optional logical group within the same provider (e.g. `"general"`,
    /// `"video"` for MiniMax; nil for non-grouped metrics).
    let group: String?

    /// Optional time window label (e.g. `"5h"`, `"weekly"`, `"monthly"`);
    /// nil for metrics that are not windowed (e.g. DeepSeek balance).
    let window: String?

    /// Whether this metric should render in the menu bar. Defaults to `true`
    /// so that newly-discovered metrics show up immediately without users
    /// having to opt in one by one.
    var displayInMenuBar: Bool

    /// Custom short name for the menu bar icon (2-3 uppercase letters/digits).
    /// When `nil`, the instance-level `shortName` is used as a fallback so
    /// all metrics of the same instance share the same label by default.
    var shortName: String?

    enum CodingKeys: String, CodingKey {
        case key
        case group
        case window
        case displayInMenuBar = "display_in_menu_bar"
        case shortName = "short_name"
    }

    init(
        key: String,
        group: String? = nil,
        window: String? = nil,
        displayInMenuBar: Bool = true,
        shortName: String? = nil
    ) {
        self.key = key
        self.group = group
        self.window = window
        self.displayInMenuBar = displayInMenuBar
        self.shortName = shortName
    }
}
