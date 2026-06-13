import Foundation

// MARK: - CopilotSupplier

struct CopilotSupplier: Supplier {
    let provider: Provider = .githubCopilot

    private let networkClient = NetworkClient.shared
    private let parser = CopilotResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://api.github.com/copilot_internal/user")!,
            headers: ["Accept": "application/json"]
        )

        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        return try parser.parse(response)
    }
}
