import Foundation

// MARK: - KimiSupplier

struct KimiSupplier: Supplier {
    let provider: Provider = .kimi

    private let networkClient = NetworkClient.shared
    private let parser = KimiResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://api.kimi.com/coding/v1/usages")!
        )

        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        let result = try parser.parse(response)
        logger.info("Kimi usage: 5h=\(result.rawData["kimi"] ?? "unknown")%, weekly=\(result.rawData["kimi:weekly_percent"] ?? "unknown")%")
        return result
    }
}
