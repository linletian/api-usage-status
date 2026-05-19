import Foundation

// MARK: - Provider

enum Provider: String, Codable, CaseIterable {
    case minimax
    case deepseek

    var displayName: String {
        switch self {
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        }
    }
}

// MARK: - Supplier

protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}