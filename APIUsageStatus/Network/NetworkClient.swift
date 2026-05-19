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
                logger.error("HTTP error: statusCode=\(httpResponse.statusCode)")
                throw RefreshError.httpError(statusCode: httpResponse.statusCode)
            }

            logger.debug("Request succeeded: \(endpoint.url)")
            return data
        } catch let error as URLError {
            // All URLError codes are network-level failures, map to appropriate RefreshError.
            // DNS failures, SSL errors, connection refused, etc. are all network issues, not API errors.
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