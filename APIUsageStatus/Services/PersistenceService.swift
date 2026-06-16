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

    func loadInstances() -> ([Instance], GlobalSettings, Bool) {
        let url = instancesFileURL

        guard fileManager.fileExists(atPath: url.path) else {
            logger.info("instances.json not found, returning defaults")
            return ([], .default, false)
        }

        do {
            let data = try Data(contentsOf: url)

            if let container = try? JSONDecoder().decode(InstancesContainer.self, from: data) {
                if container.needsMigration {
                    logger.info("instances.json schemaVersion=\(container.schemaVersion) < \(InstancesContainer.currentSchemaVersion); auto-migrating...")
                    try? saveInstances(container.instances, settings: container.settings)
                    return (container.instances, container.settings, false)
                }
                logger.info("Loaded \(container.instances.count) instances from disk (schemaVersion=\(container.schemaVersion))")
                return (container.instances, container.settings, false)
            }

            let (instances, settings) = try decodeAndMigrateV1(data)
            return (instances, settings, false)
        } catch {
            logger.fault("Failed to load instances.json: \(error.localizedDescription)")
            return ([], .default, false)
        }
    }

    func saveInstances(_ instances: [Instance], settings: GlobalSettings) throws {
        let container = InstancesContainer(
            instances: instances,
            settings: settings,
            schemaVersion: InstancesContainer.currentSchemaVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(container)
        try fileManager.atomicWrite(data: data, to: instancesFileURL)
        logger.info("Saved \(instances.count) instances to disk (schemaVersion=\(container.schemaVersion))")
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

    // MARK: - V1 → V2 Migration

    /// Decodes a single instance from the v1 on-disk shape, where
    /// `dimension` and `enabled` were the canonical fields (before
    /// `metrics` and `trackingEnabled` replaced them in v2).
    private struct _V1Instance: Decodable {
        let uuid: String
        let provider: String
        let dimension: String
        let displayName: String
        let shortName: String
        let apiKeyRef: String
        let enabled: Bool
        let sortOrder: Int
        let currency: String?
        let thresholds: Thresholds

        enum CodingKeys: String, CodingKey {
            case uuid, provider, dimension
            case displayName = "display_name"
            case shortName = "short_name"
            case apiKeyRef = "api_key_ref"
            case enabled
            case sortOrder = "sort_order"
            case currency, thresholds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try container.decode(String.self, forKey: .uuid)
            provider = try container.decode(String.self, forKey: .provider)
            dimension = try container.decode(String.self, forKey: .dimension)
            displayName = try container.decode(String.self, forKey: .displayName)
            shortName = try container.decode(String.self, forKey: .shortName)
            apiKeyRef = try container.decode(String.self, forKey: .apiKeyRef)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            sortOrder = try container.decode(Int.self, forKey: .sortOrder)
            currency = try container.decodeIfPresent(String.self, forKey: .currency)
            thresholds = try container.decode(Thresholds.self, forKey: .thresholds)
        }
    }

    /// Top-level container matching the v1 on-disk shape so that
    /// `PersistenceService` can decode a full legacy `instances.json`
    /// without touching the modern `Instance` decoder.
    private struct _V1InstancesContainer: Decodable {
        let schemaVersion: Int
        let instances: [_V1Instance]
        let settings: GlobalSettings

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case instances
            case settings
        }
    }

    /// Converts a v1 instance to the current v2 shape.
    /// `dimension` → `metrics[0].key`, `enabled` → `trackingEnabled`.
    private func migrateV1Instance(_ v1: _V1Instance) -> Instance {
        Instance(
            uuid: v1.uuid,
            provider: v1.provider,
            dimension: v1.dimension,
            displayName: v1.displayName,
            shortName: v1.shortName,
            apiKeyRef: v1.apiKeyRef,
            enabled: v1.enabled,
            sortOrder: v1.sortOrder,
            currency: v1.currency,
            thresholds: v1.thresholds
        )
    }

    /// Attempts to decode `data` as a v1 container and migrate every
    /// instance to the current schema. Creates a `.backup` of the old
    /// file before writing; if the write fails the backup is preserved
    /// and the original file is untouched.
    private func decodeAndMigrateV1(_ data: Data) throws -> ([Instance], GlobalSettings) {
        let legacyContainer = try JSONDecoder().decode(_V1InstancesContainer.self, from: data)
        logger.info("Detected v1 instances.json (schemaVersion=\(legacyContainer.schemaVersion)); migrating \(legacyContainer.instances.count) instance(s)...")

        let migratedInstances = legacyContainer.instances.map { migrateV1Instance($0) }

        let backupURL = instancesFileURL.appendingPathExtension("backup")
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: instancesFileURL, to: backupURL)
            logger.info("Created backup at instances.json.backup before migration")
        } catch {
            logger.fault("Failed to create backup before migration: \(error.localizedDescription)")
            throw PersistenceError.writeFailed("Cannot create backup before migration: \(error.localizedDescription)")
        }

        try saveInstances(migratedInstances, settings: legacyContainer.settings)
        logger.info("Migration complete: \(migratedInstances.count) instance(s) saved with schemaVersion=\(InstancesContainer.currentSchemaVersion)")

        return (migratedInstances, legacyContainer.settings)
    }
}

    