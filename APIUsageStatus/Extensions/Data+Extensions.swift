import Foundation

// MARK: - Data + UTF8Preview

extension Data {
    /// Truncated UTF-8 preview for diagnostic logging.
    ///
    /// Decode a byte window first, THEN cut by character: slicing `maxChars`
    /// raw bytes can cut through a multi-byte UTF-8 sequence and make
    /// `String(data:encoding:)` return `nil` — exactly when we most need the
    /// body (Kimi error strings are often Chinese, 3 bytes per character).
    /// See `docs/kimi-api-failures-investigation.md`.
    func utf8Preview(maxBytes: Int = 4096, maxChars: Int = 512) -> String {
        guard let decoded = String(data: prefix(maxBytes), encoding: .utf8) else {
            return "<undecodable UTF-8, \(count) bytes>"
        }
        return String(decoded.prefix(maxChars))
    }
}
