import Foundation

// MARK: - Endpoint

struct Endpoint {
    let url: URL
    let method: String
    let headers: [String: String]
    let timeout: TimeInterval

    init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
    }

    static func get(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 30) -> Endpoint {
        Endpoint(url: url, method: "GET", headers: headers, timeout: timeout)
    }
}