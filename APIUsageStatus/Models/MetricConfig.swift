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
///
/// Codable contract (pinned by `MetricConfigCodableTests`):
/// - Decoding is lenient: only `key` is required. Missing `group` / `window` /
///   `short_name` decode as nil and a missing `display_in_menu_bar` defaults
///   to `true`, so entries written by older builds can never fail the whole
///   `instances.json` load with `keyNotFound`.
/// - Encoding always writes `key` / `group` / `window` / `display_in_menu_bar`
///   (nil optionals as explicit `null`) and writes `short_name` only when set.
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

    /// Lenient decoding: everything except `key` falls back to its default
    /// when absent, mirroring `Instance.init(from:)`. A metric entry written
    /// before a field existed must not fail the whole container decode
    /// (`PersistenceService.getInstances` swallows a throw as "no instances").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        window = try container.decodeIfPresent(String.self, forKey: .window)
        displayInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .displayInMenuBar) ?? true
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
    }

    /// Stable on-disk shape: the core `(key, group, window)` triple and
    /// `display_in_menu_bar` are always present (nil optionals as explicit
    /// `null`); `short_name` is written only when customized.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(group, forKey: .group)
        try container.encode(window, forKey: .window)
        try container.encode(displayInMenuBar, forKey: .displayInMenuBar)
        try container.encodeIfPresent(shortName, forKey: .shortName)
    }
}
