import ServiceManagement
import Foundation

// MARK: - AppLaunchService

struct AppLaunchService {
    private let logger = AppLogger(category: "launch")

    @discardableResult
    func register() -> Bool {
        do {
            try SMAppService.mainApp.register()
            logger.info("SMAppService registered for launch at login")
            return true
        } catch {
            logger.warning("Failed to register SMAppService (may be expected with ad-hoc signing): \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func unregister() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            logger.info("SMAppService unregistered from launch at login")
            return true
        } catch {
            logger.warning("Failed to unregister SMAppService: \(error.localizedDescription)")
            return false
        }
    }

    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
