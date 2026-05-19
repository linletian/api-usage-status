import Foundation

struct Instance: Codable, Identifiable, Equatable {
    let uuid: String
    var provider: String
    var dimension: String
    var displayName: String
    var shortName: String
    var apiKeyRef: String
    var enabled: Bool
    var sortOrder: Int
    var currency: String?
    var thresholds: Thresholds

    enum CodingKeys: String, CodingKey {
        case uuid
        case provider
        case dimension
        case displayName = "display_name"
        case shortName = "short_name"
        case apiKeyRef = "api_key_ref"
        case enabled
        case sortOrder = "sort_order"
        case currency
        case thresholds
    }

    init(
        uuid: String = UUID().uuidString,
        provider: String,
        dimension: String,
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
        self.dimension = dimension
        self.displayName = displayName
        self.shortName = shortName
        self.apiKeyRef = apiKeyRef
        self.enabled = enabled
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
}