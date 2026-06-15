import Foundation

// MARK: - PersistenceError

enum PersistenceError: Error, Equatable {
    case fileNotFound
    case readFailed(String)
    case writeFailed(String)
    case encodingFailed
    case decodingFailed(String)
}

// MARK: - PersistenceService

actor PersistenceService {
    private let keychainService: KeychainService
    private let logger = AppLogger(category: "persistence")
    private let fileManager = FileManager.default

    /// The Application Support directory within the sandbox container
    var applicationSupportDirectory: URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = urls[0].appendingPathComponent("APIUsageStatus", isDirectory: true)

        // Ensure directory exists
        if !fileManager.fileExists(atPath: appSupport.path) {
            try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }

        return appSupport
    }

    private var instancesFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("instances.json")
    }

    init(keychainService: KeychainService) {
        self.keychainService = keychainService
    }

    // MARK: - Instances (load / save)

    func loadInstances() -> ([Instance], GlobalSettings) {
        let url = instancesFileURL

        guard fileManager.fileExists(atPath: url.path) else {
            logger.info("instances.json not found, returning defaults")
            return ([], .default)
        }

        do {
            let data = try Data(contentsOf: url)
            let container = try JSONDecoder().decode(InstancesContainer.self, from: data)
            logger.info("Loaded \(container.instances.count) instances from disk")
            return (container.instances, container.settings)
        } catch let error as DecodingError {
            logger.fault("Failed to decode instances.json: \(error.localizedDescription)")
            return ([], .default)
        } catch {
            logger.fault("Failed to read instances.json: \(error.localizedDescription)")
            return ([], .default)
        }
    }

    func saveInstances(_ instances: [Instance], settings: GlobalSettings) throws {
        let container = InstancesContainer(instances: instances, settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(container)
        try fileManager.atomicWrite(data: data, to: instancesFileURL)
        logger.info("Saved \(instances.count) instances to disk")
    }

    // MARK: - Balance Snapshot (load / save per instance)

    func loadBalanceSnapshot(for uuid: String) -> BalanceSnapshot? {
        let url = applicationSupportDirectory.appendingPathComponent("\(uuid).json")

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(BalanceSnapshot.self, from: data)
            return snapshot
        } catch let error as DecodingError {
            logger.fault("Failed to decode balance snapshot for \(uuid): \(error.localizedDescription)")
            return nil
        } catch {
            logger.fault("Failed to read balance snapshot for \(uuid): \(error.localizedDescription)")
            return nil
        }
    }

    func saveBalanceSnapshot(_ snapshot: BalanceSnapshot, for uuid: String) throws {
        let url = applicationSupportDirectory.appendingPathComponent("\(uuid).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try fileManager.atomicWrite(data: data, to: url)
    }

    func deleteBalanceSnapshot(for uuid: String) throws {
        let url = applicationSupportDirectory.appendingPathComponent("\(uuid).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            logger.debug("Deleted balance snapshot for \(uuid)")
        }
    }

    // MARK: - API Key delegation to KeychainService

    func getApiKey(for apiKeyRef: String) async -> String? {
        return await keychainService.retrieve(for: apiKeyRef)
    }

    func saveApiKey(_ key: String, for apiKeyRef: String) async throws {
        try await keychainService.store(key: key, for: apiKeyRef)
    }

    func deleteApiKey(for apiKeyRef: String) async throws {
        try await keychainService.delete(for: apiKeyRef)
    }

    /// Ensure the OpenCode placeholder key exists in the keychain. Called at
    /// app launch so any OpenCode instance's `apiKeyRef` resolves to a
    /// non-nil value (the supplier ignores the value, but the keychain
    /// lookup must succeed).
    func ensureOpenCodePlaceholder() async throws {
        try await keychainService.ensureOpenCodePlaceholder()
    }

    // MARK: - Instance Deletion Cleanup

    /// Cleans up all data associated with an instance being deleted.
    /// - Parameters:
    ///   - instance: The instance being deleted
    ///   - allInstances: All currently saved instances (after removal)
    func deleteInstance(_ instance: Instance, allInstances: [Instance]) async throws {
        // 1. Delete the balance snapshot JSON
        try deleteBalanceSnapshot(for: instance.uuid)

        // 2. Check if any other instance shares the same api_key_ref
        let hasSharedRef = allInstances.contains { $0.apiKeyRef == instance.apiKeyRef }

        if !hasSharedRef {
            // 3. Delete the Keychain entry
            try await keychainService.delete(for: instance.apiKeyRef)
        }

        logger.info("Cleaned up data for deleted instance: \(instance.displayName) (\(instance.uuid))")
    }
}

    