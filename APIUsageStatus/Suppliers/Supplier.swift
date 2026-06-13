import Foundation

// MARK: - Provider

enum Provider: String, Codable, CaseIterable {
    case minimax
    case deepseek
    case githubCopilot

    var displayName: String {
        switch self {
        case .minimax: return "MiniMax"
        case .deepseek: return "DeepSeek"
        case .githubCopilot: return "GitHub Copilot"
        }
    }
}

// MARK: - Supplier

protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}