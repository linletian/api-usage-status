import Foundation

struct Instance: Codable, Identifiable, Equatable {
    let uuid: String
    var provider: String
    var metrics: [MetricConfig]
    var displayName: String
    var shortName: String
    var apiKeyRef: String
    var trackingEnabled: Bool
    var sortOrder: Int
    var currency: String?
    var thresholds: Thresholds

    /// Computed bridge for backward compatibility.
    /// SettingsViewModel.setInstanceEnabled writes to this setter.
    var enabled: Bool {
        get { trackingEnabled }
        set { trackingEnabled = newValue }
    }

    /// Derived from the first persisted metric; returns "" when empty.
    var dimension: String { metrics.first?.key ?? "" }

    enum CodingKeys: String, CodingKey {
        case uuid
        case provider
        case metrics
        case displayName = "display_name"
        case shortName = "short_name"
        case apiKeyRef = "api_key_ref"
        case trackingEnabled = "tracking_enabled"
        case sortOrder = "sort_order"
        case currency
        case thresholds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        provider = try container.decode(String.self, forKey: .provider)

        // Metrics array is the canonical persisted shape;
        // dimension is no longer decoded — it is computed from metrics.
        metrics = try container.decodeIfPresent([MetricConfig].self, forKey: .metrics) ?? []

        displayName = try container.decode(String.self, forKey: .displayName)
        shortName = try container.decode(String.self, forKey: .shortName)
        apiKeyRef = try container.decode(String.self, forKey: .apiKeyRef)
        trackingEnabled = try container.decode(Bool.self, forKey: .trackingEnabled)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
        thresholds = try container.decode(Thresholds.self, forKey: .thresholds)
    }

    init(
        uuid: String = UUID().uuidString,
        provider: String,
        dimension: String,
        metrics: [MetricConfig] = [],
        displayName: String = "",
        shortName: String = "",
        apiKeyRef: String,
        enabled: Bool = true,
        sortOrder: Int = 0,
        currency: String? = nil,
        thresholds: Thresholds
    ) {
        self.uuid = uuid
        self.provider = provider
        if metrics.isEmpty && !dimension.isEmpty {
            self.metrics = [MetricConfig(key: dimension, group: nil, window: nil, displayInMenuBar: true)]
        } else {
            self.metrics = metrics
        }
        self.displayName = displayName
        self.shortName = shortName
        self.apiKeyRef = apiKeyRef
        self.trackingEnabled = enabled
        self.sortOrder = sortOrder
        self.currency = currency
        self.thresholds = thresholds
    }

    var isQuotaType: Bool {
        switch thresholds {
        case .quota: return true
        case .balance: return false
        }
    }

    var isBalanceType: Bool {
        switch thresholds {
        case .quota: return false
        case .balance: return true
        }
    }

    var id: String { uuid }
}
