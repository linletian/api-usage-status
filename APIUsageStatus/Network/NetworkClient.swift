import Foundation

// MARK: - NetworkClient

actor NetworkClient {
    private let session: URLSession
    private let logger = AppLogger(category: "network")

    static let shared = NetworkClient()

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func request(_ endpoint: Endpoint, apiKey: String) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint.url)
        urlRequest.httpMethod = endpoint.method
        urlRequest.timeoutInterval = endpoint.timeout

        // Set Authorization header
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Apply custom headers
        for (key, value) in endpoint.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RefreshError.networkUnreachable
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                // Diagnostic payload: the response body is logged at
                // `privacy: .public` so `log show` / Console.app can reveal
                // it — the default `\(value)` interpolation in `os.Logger`
                // would render as `<private>` and make this whole branch
                // useless for the Kimi API diagnosis (see
                // `docs/kimi-api-failures-investigation.md`).
                //
                // Leak-surface note: response bodies for some suppliers
                // (notably OpenCode, which reads local SQLite) can contain
                // server-defined user identifiers. Marking the body
                // `.public` is a deliberate diagnostic choice for the
                // failure path; do not extend this to success-path logging
                // without re-evaluating the privacy contract.
                //
                // Truncation: decode a 4 KB byte window first, THEN take
                // the first 512 *characters*. Cutting 512 raw bytes can
                // slice through a multi-byte UTF-8 sequence and yield
                // `nil` from `String(data:encoding:)` — exactly when we
                // most need the body.
                let bodyData = data.prefix(4096)
                let bodyPreview: String
                if let s = String(data: bodyData, encoding: .utf8) {
                    bodyPreview = String(s.prefix(512))
                } else {
                    bodyPreview = "<undecodable UTF-8, \(data.count) bytes>"
                }
                logger.publicError(
                    "HTTP error: url=\(endpoint.url.absoluteString, privacy: .public), statusCode=\(httpResponse.statusCode, privacy: .public), body=\(bodyPreview, privacy: .public)"
                )
                throw RefreshError.httpError(statusCode: httpResponse.statusCode)
            }

            logger.debug("Request succeeded: \(endpoint.url)")
            return data
        } catch let error as URLError {
            // Cancellation: when the parent task is cancelled mid-request,
            // URLSession throws .cancelled. This is NOT a network failure
            // — propagating it as `.networkUnreachable` would cause
            // RetryPolicy to retry it as if the network was flaky, which
            // both wastes 30s and obscures the real cause. Re-raise the
            // cancellation so callers see the real intent.
            if error.code == .cancelled {
                throw CancellationError()
            }
            let mappedError = mapURLError(error)
            logger.error("URLError [\(error.code.rawValue)]: \(error.localizedDescription)")
            throw mappedError
        } catch let error as RefreshError {
            throw error
        }
    }

    private func mapURLError(_ error: URLError) -> RefreshError {
        switch error.code {
        case .timedOut:
            return .networkTimeout
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed,
             .cannotFindHost, .cannotConnectToHost,
             .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected,
             .clientCertificateRequired, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .networkUnreachable
        default:
            // All other URLError variants are network-level failures
            // (cancelled, backgroundSessionRequiresSharedContainer, etc.)
            return .networkUnreachable
        }
    }
}