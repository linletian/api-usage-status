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
        return try parser.parse(response)
    }
}