import Foundation

/// Fetches OpenCode Go usage from the official HTTP API
/// (`GET https://opencode.ai/zen/go/v1/usage`, shipped via anomalyco/opencode
/// PR #16513). The server reports the three plan windows (rolling 5h,
/// weekly, monthly) as used-percent + absolute reset time, counting only
/// plan (lite) usage — balance top-up consumption is excluded and the values
/// are consistent across devices.
///
/// Requires a Zen API key (created at opencode.ai → workspace → API keys),
/// entered manually in Settings. All OpenCode instances share one keychain
/// entry (`KeychainService.openCodePlaceholderRef`); `RefreshService`
/// de-dupes the fetch, so `fetchUsage` runs once per cycle and writes all
/// three windows into `rawData`. Each `Instance` then picks its own window
/// via `mapInstanceToSlotData`.
struct OpenCodeSupplier: Supplier {
    let provider: Provider = .opencode

    private let networkClient = NetworkClient.shared
    private let parser = OpenCodeResponseParser()
    private let logger = AppLogger(category: "opencode-supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        guard !apiKey.isEmpty else {
            throw RefreshError.parsingError(
                "OpenCode Go now uses the official usage API — paste a Zen API key (opencode.ai → workspace → API keys) in Settings"
            )
        }

        let endpoint = Endpoint.get(
            url: URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            // Error bodies are `{type, error:{type, message}}` diagnostics
            // without PII — opting in keeps 401/403 responses visible in logs.
            exposesFailureBodyInLog: true
        )
        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        let parsed: OpenCodeResponseParser.Parsed
        do {
            parsed = try parser.parse(response)
        } catch {
            // Diagnostic payload: usage numbers only, no PII — same contract
            // as KimiSupplier's parse-failure log.
            logger.osLogger.error(
                "OpenCode usage parse failed: url=\(endpoint.url.absoluteString, privacy: .public); error=\(String(describing: error), privacy: .public); body=\(response.utf8Preview(), privacy: .public)"
            )
            throw error
        }
        logger.info("OpenCode usage: 5h=\(parsed.fiveHour.percent)%, weekly=\(parsed.weekly.percent)%, monthly=\(parsed.monthly.percent)%")
        return Self.makeResponse(from: parsed)
    }

    // MARK: - rawData key design

    /// Keys follow the existing convention: bare key for the percent and
    /// `<dim>:end_time` for the absolute reset time that `RefreshService`
    /// already knows how to read. The API reports no absolute dollar
    /// amounts, so the retired local-SQLite path's `<dim>:used` /
    /// `<dim>:limit` keys are no longer written.
    static func makeResponse(from parsed: OpenCodeResponseParser.Parsed) -> SupplierResponse {
        var raw: [String: String] = [:]
        for (dim, window) in [
            ("5h", parsed.fiveHour),
            ("weekly", parsed.weekly),
            ("monthly", parsed.monthly)
        ] {
            raw[dim] = String(format: "%.1f", window.percent)
            raw["\(dim):end_time"] = String(window.endTimeMs)
        }
        return SupplierResponse(rawData: raw, currency: nil, isAvailable: true)
    }
}
