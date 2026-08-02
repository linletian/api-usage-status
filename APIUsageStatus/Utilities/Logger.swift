import Foundation
import os

// MARK: - Logger

struct AppLogger {
    /// Direct access to the underlying `os.Logger`, for diagnostic call
    /// sites that need `privacy: .public` interpolations. `os.Logger`
    /// methods require a string-interpolation literal at the call site —
    /// the compiler rejects a forwarded `OSLogMessage` value ("argument
    /// must be a string interpolation") — so a `publicError(_:)` wrapper
    /// on `AppLogger` cannot exist. Call
    /// `logger.osLogger.error("...\(value, privacy: .public)...")`
    /// directly instead; the literal requirement also means the privacy
    /// annotations cannot be silently dropped.
    ///
    /// Use `.public` ONLY for diagnostic payloads that are safe to
    /// surface in the system log — never for tokens, secrets, or PII.
    /// For Kimi the body is quota numbers (no PII), so this is safe; the
    /// generic NetworkClient path redacts bodies unless the endpoint
    /// opted in via `Endpoint.exposesFailureBodyInLog`.
    ///
    /// TODO(pr15-followup): narrow this exposure. Exposing the raw
    /// `os.Logger` means any future call site can write
    /// `logger.osLogger.fault("\(token, privacy: .public)")` and bypass
    /// the "bodies default to .private" policy without a compiler
    /// error. A spec wrapper such as `func publicError(_ literal:
    /// StaticString, _ args: CVarArg...)` — or a DEBUG-only gate —
    /// would keep `.public` use opt-in and greppable. Revisit once the
    /// Kimi diagnostic logging is retired (see
    /// `docs/kimi-api-failures-investigation.md` §9).
    var osLogger: os.Logger { logger }

    private let logger: os.Logger

    init(category: String) {
        self.logger = os.Logger(subsystem: "com.example.APIUsageStatus", category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message)")
    }

    func info(_ message: String) {
        logger.info("\(message)")
    }

    func warning(_ message: String) {
        logger.warning("\(message)")
    }

    func error(_ message: String) {
        logger.error("\(message)")
    }

    func fault(_ message: String) {
        logger.fault("\(message)")
    }
}

// MARK: - Module Loggers

extension AppLogger {
    static let refresh = AppLogger(category: "refresh")
    static let persistence = AppLogger(category: "persistence")
    static let network = AppLogger(category: "network")
    static let keychain = AppLogger(category: "keychain")
    static let supplier = AppLogger(category: "supplier")
    static let render = AppLogger(category: "render")
    static let opencode = AppLogger(category: "opencode")
    static let app = AppLogger(category: "app")
    static let lifecycle = AppLogger(category: "lifecycle")
}