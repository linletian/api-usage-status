import Foundation

// MARK: - MetricSnapshot

/// Runtime snapshot for a single metric — the value the UI binds to.
///
/// A snapshot is **always** derived at refresh time from a `MetricConfig`
/// plus the latest supplier response. It is intentionally **not** `Codable`:
/// transient fields (percent, display strings, remaining cycle seconds,
/// color state, runtime config index) must never be persisted to
/// `instances.json`. Persisting snapshots would mix config and runtime
/// state, and would require invalidation logic on every refresh.
///
/// If you need to add a field that should outlive a single refresh, promote
/// it onto `MetricConfig` instead — keeping config and runtime strictly
/// separated is the whole point of this type.
struct MetricSnapshot: Equatable {
    /// Identical to `MetricConfig.key` for the config this snapshot was
    /// built from. Used to correlate snapshots back to configs in tests
    /// and logging.
    let key: String

    /// Same as `MetricConfig.group`. Optional because not every metric
    /// is grouped (e.g. DeepSeek balance has no inner group).
    let group: String?

    /// Same as `MetricConfig.window`. Optional because not every metric
    /// is windowed (balance metrics have no cycle).
    let window: String?

    /// Usage percentage in the current window (0–100). For balance metrics
    /// this may not be meaningful — see `displayUsage` / `displayLimit`.
    let percent: Double

    /// Pre-formatted usage string ready for direct rendering (e.g. `"28.0%"`,
    /// `"¥42.50"`). Never empty — the parser is responsible for choosing a
    /// sensible fallback before constructing a snapshot.
    let displayUsage: String

    /// Pre-formatted limit string ready for direct rendering (e.g. `"5000"`,
    /// `"¥100.00"`). May be empty for metrics that have no upper bound.
    let displayLimit: String

    /// Absolute end time of the current reset cycle. `nil` for metrics that
    /// are not windowed (balance) or when the API does not provide it. The
    /// view layer combines this with `Date()` to render a live "Xh Ym
    /// remaining" countdown via `TimelineView` — kept as an absolute `Date`
    /// (not a relative seconds snapshot) so the countdown ticks down
    /// smoothly between refreshes.
    let cycleEndTime: Date?

    /// Seconds remaining in the current reset cycle at the moment the
    /// snapshot was built. Derived from `cycleEndTime` for the same refresh
    /// tick. Kept as a separate field for callers (tests, `SlotViewData`)
    /// that want a static value without re-deriving it from `Date()`.
    let cycleRemainingSeconds: Int?

    /// Aggregated state the renderer uses to pick a color. Computed at
    /// refresh time from thresholds + the parsed percent.
    let colorState: ColorState

    /// 1-based position of this snapshot's config in the user's persisted
    /// config list, used for stable ordering in the menu bar and panel.
    /// 0 means "unset" (default-init snapshots used in tests).
    let configIndex: Int

    /// Whether the owning `MetricConfig` has `displayInMenuBar` enabled.
    /// Defaults to `true` so synthetic snapshots (legacy balance instances,
    /// tests) render in the menu bar by default.
    let displayInMenuBar: Bool

    /// True when the API reports the window is not active for the user's plan
    /// (e.g. MiniMax `current_weekly_status != 1`). The UI renders a flowing
    /// glow bar instead of a progress bar when this is set.
    let isUnlimited: Bool

    /// Custom short name propagated from `MetricConfig.shortName`.
    /// When `nil` the menu bar renderer falls back to the instance short name.
    let shortName: String?

    init(
        key: String,
        group: String?,
        window: String?,
        percent: Double,
        displayUsage: String,
        displayLimit: String,
        cycleRemainingSeconds: Int?,
        colorState: ColorState,
        configIndex: Int = 0,
        displayInMenuBar: Bool = true,
        isUnlimited: Bool = false,
        shortName: String? = nil,
        cycleEndTime: Date? = nil
    ) {
        self.key = key
        self.group = group
        self.window = window
        self.percent = percent
        self.displayUsage = displayUsage
        self.displayLimit = displayLimit
        self.cycleEndTime = cycleEndTime
        self.cycleRemainingSeconds = cycleRemainingSeconds
        self.colorState = colorState
        self.configIndex = configIndex
        self.displayInMenuBar = displayInMenuBar
        self.isUnlimited = isUnlimited
        self.shortName = shortName
    }
}
