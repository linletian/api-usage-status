import Foundation

// MARK: - MiniMaxSupplier

struct MiniMaxSupplier: Supplier {
    let provider: Provider = .minimax

    private let networkClient = NetworkClient.shared
    private let parser = MiniMaxResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!
        )

        let response = try await networkClient.request(endpoint, apiKey: apiKey)

        let result = try parser.parse(response)
        logger.debug("MiniMax response parsed: \(result.rawData)")
        return result
    }
}