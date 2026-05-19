import Foundation

// MARK: - DeepSeekSupplier

struct DeepSeekSupplier: Supplier {
    let provider: Provider = .deepseek

    private let networkClient = NetworkClient.shared
    private let parser = DeepSeekResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://api.deepseek.com/user/balance")!
        )

        let response = try await networkClient.request(endpoint, apiKey: apiKey)

        let result = try parser.parse(response)
        logger.info("DeepSeek balance: \(result.rawData["balance"] ?? "unknown"), available: \(result.isAvailable)")
        return result
    }
}