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
        let result: SupplierResponse
        do {
            result = try parser.parse(response)
        } catch {
            // Diagnostic payload: Kimi response bodies are quota numbers
            // (no PII, no token echo), so logging at `privacy: .public` is
            // safe and the only way `log show` will surface anything
            // useful — see AppLogger.osLogger for the contract. URL +
            // provider are tagged so a 401 from a different supplier
            // running in parallel is not confused for Kimi. Truncation:
            // decode a 4 KB byte window first, then truncate by character
            // (Chinese error strings are common from Kimi and would be
            // destroyed by a raw byte cut). See
            // `docs/kimi-api-failures-investigation.md`.
            let bodyData = response.prefix(4096)
            let bodyPreview: String
            if let s = String(data: bodyData, encoding: .utf8) {
                bodyPreview = String(s.prefix(512))
            } else {
                bodyPreview = "<undecodable UTF-8, \(response.count) bytes>"
            }
            logger.osLogger.error(
                "Kimi response parse failed: provider=\(provider.rawValue, privacy: .public), url=\(endpoint.url.absoluteString, privacy: .public); error=\(error, privacy: .public); body=\(bodyPreview, privacy: .public)"
            )
            throw error
        }
        logger.info("Kimi usage: 5h=\(result.rawData["kimi"] ?? "unknown")%, weekly=\(result.rawData["kimi:weekly_percent"] ?? "unknown")%")
        return result
    }
}
