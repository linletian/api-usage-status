import Foundation

// MARK: - MetricCycleEndPolicy

/// Provider-neutral instruction that a parser emits for a single metric to
/// tell the generic snapshot builder how to react when the supplier does not
/// return a usable cycle end time. Kept in the response model so shared
/// orchestration in `RefreshService` can execute it without checking
/// provider identities.
///
/// Default for every provider and metric is `useResponseOnly`. A parser opts
/// in to fallback semantics per metric key (e.g. Kimi 5h) by emitting
/// `retainPreviousIfResponseMissing` only when the response itself
/// cannot provide a fresh end time. Other providers and metrics never
/// publish a policy, so their behavior is unchanged.
enum MetricCycleEndPolicy: Equatable {
    /// The mapper uses only the response. Missing end time yields `nil`.
    case useResponseOnly

    /// If the response cannot yield a positive end time, the mapper may
    /// inherit an unexpired absolute end time from the cached snapshot
    /// for the same metric identity, recomputing remaining seconds against
    /// the current time. The mapper never freezes a stale value past
    /// `cachedEnd > now`.
    case retainPreviousIfResponseMissing
}

// MARK: - SupplierResponse

/// Represents the parsed response from a supplier API.
/// The rawData dictionary contains dimension-identified values, and
/// `metricCycleEndPolicies` carries optional per-metric fallback
/// policies. The supplier layer sets a policy only when the API cannot
/// supply a fresh end time and inheriting an unexpired previous value
/// matches the user-visible intent.
struct SupplierResponse: Equatable {
    /// Maps internal dimension identifiers to their values.
    /// For MiniMax: model_name values (e.g., "MiniMax-M2.7", "speech-hd", "music-2.6")
    /// For DeepSeek: "balance"
    let rawData: [String: String]

    /// The currency returned by the API (e.g., "CNY", "USD"), if present.
    let currency: String?

    /// Whether the account is available (DeepSeek-specific).
    let isAvailable: Bool

    /// Per-metric cycle-end fallback policy, keyed by `MetricConfig.key`
    /// (e.g. `"kimi"`, `"kimi:weekly_percent"`). Default is empty; parsers
    /// only set an entry when the response is missing a usable end time
    /// and the supplier's UX contract wants the previous snapshot's
    /// unexpired end time to be retained.
    let metricCycleEndPolicies: [String: MetricCycleEndPolicy]

    init(
        rawData: [String: String],
        currency: String? = nil,
        isAvailable: Bool = true,
        metricCycleEndPolicies: [String: MetricCycleEndPolicy] = [:]
    ) {
        self.rawData = rawData
        self.currency = currency
        self.isAvailable = isAvailable
        self.metricCycleEndPolicies = metricCycleEndPolicies
    }

    func value(forDimension dimension: String) -> String? {
        rawData[dimension]
    }
}
