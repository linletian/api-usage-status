import Foundation
import os

// MARK: - Logger

struct AppLogger {
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

    // MARK: - Convenience with privacy

    func debug(_ message: String, privacy: os.Logger.Privacy) {
        logger.debug("\(message, privacy: privacy)")
    }

    func info(_ message: String, privacy: os.Logger.Privacy) {
        logger.info("\(message, privacy: privacy)")
    }

    func error(_ message: String, privacy: os.Logger.Privacy) {
        logger.error("\(message, privacy: privacy)")
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
    static let app = AppLogger(category: "app")
}