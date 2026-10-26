import Foundation

// MARK: - Endpoint

struct Endpoint {
    let url: URL
    let method: String
    let headers: [String: String]
    let timeout: TimeInterval
    /// Opt-in: allow `NetworkClient` to log this endpoint's failure response
    /// body at `privacy: .public`. Error bodies from upstream gateways can
    /// echo credential fragments or account identifiers, so the default is
    /// `false` (body rendered `<private>`); enable only for endpoints whose
    /// error bodies are known to be PII-free — currently Kimi (see
    /// `docs/kimi-api-failures-investigation.md`) and OpenCode Go (generic
    /// `{type, error}` JSON).
    let exposesFailureBodyInLog: Bool

    init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        timeout: TimeInterval = 30,
        exposesFailureBodyInLog: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
        self.exposesFailureBodyInLog = exposesFailureBodyInLog
    }

    static func get(
        url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30,
        exposesFailureBodyInLog: Bool = false
    ) -> Endpoint {
        Endpoint(
            url: url,
            method: "GET",
            headers: headers,
            timeout: timeout,
            exposesFailureBodyInLog: exposesFailureBodyInLog
        )
    }
}