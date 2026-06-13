import Foundation

// MARK: - SupplierRegistry

enum SupplierRegistry {
    /// Returns the appropriate Supplier instance for the given provider.
    /// - Parameter provider: The provider identifier
    /// - Returns: A Supplier instance for the provider
    static func getSupplier(for provider: Provider) -> Supplier {
        switch provider {
        case .minimax:
            return MiniMaxSupplier()
        case .deepseek:
            return DeepSeekSupplier()
        case .githubCopilot:
            return CopilotSupplier()
        }
    }

    /// Returns the appropriate Supplier instance for the given provider string.
    /// - Parameter providerString: The provider string (e.g., "minimax", "deepseek")
    /// - Returns: A Supplier instance, or nil if the provider is unknown
    static func getSupplier(for providerString: String) -> Supplier? {
        guard let provider = Provider(rawValue: providerString) else {
            return nil
        }
        return getSupplier(for: provider)
    }
}