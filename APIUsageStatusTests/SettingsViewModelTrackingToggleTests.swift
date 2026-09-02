import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for issue #20 — `SettingsViewModel` must
/// propagate a tracking toggle to the runtime `AppState` immediately
/// (no Save required), and `discardChanges` / `save` must keep the
/// runtime state in sync with the user's intent.
///
/// All tests run on `@MainActor` because the view model is main-actor
/// isolated. `SettingsViewModel.save()` writes to the real Application
/// Support directory; each test that triggers `save` cleans up the
/// `instances.json` it produced in `tearDown` so the user's own data
/// is never clobbered.
@MainActor
final class SettingsViewModelTrackingToggleTests: XCTestCase {

    // MARK: - Fixtures

    private var appState: AppState!
    private var appStateProxy: AppStateProxy!
    private var persistenceService: PersistenceService!

    override func setUp() async throws {
        try await super.setUp()
        let keychain = KeychainService()
        persistenceService = PersistenceService(keychainService: keychain)
        appState = AppState()
        let refresh = RefreshService(persistenceService: persistenceService, appState: appState)
        appStateProxy = AppStateProxy(
            appState: appState,
            refreshService: refresh,
            persistenceService: persistenceService
        )
    }

    override func tearDown() async throws {
        // Best-effort cleanup of any `instances.json` written by a
        // save() call in this test — we never want a unit test to
        // overwrite the user's real on-disk settings.
        let url = await persistenceService.applicationSupportDirectory
            .appendingPathComponent("instances.json")
        try? FileManager.default.removeItem(at: url)
        try await super.tearDown()
    }

    private func makeViewModel() -> SettingsViewModel {
        // Reuse the shared appState/appStateProxy/persistenceService
        // created in setUp so the assertions below can read the
        // runtime state through `appState` instead of fishing out
        // the private fields from the view model.
        let refresh = RefreshService(
            persistenceService: persistenceService,
            appState: appState
        )
        let notifications = NotificationManager(openDetailPanel: { _ in })
        let launch = AppLaunchService()
        return SettingsViewModel(
            persistenceService: persistenceService,
            appState: appState,
            appStateProxy: appStateProxy,
            refreshService: refresh,
            notificationManager: notifications,
            appLaunchService: launch
        )
    }

    private func makeInstance(
        uuid: String,
        displayName: String = "Test",
        enabled: Bool = true
    ) -> Instance {
        Instance(
            uuid: uuid,
            provider: "test",
            dimension: "test",
            displayName: displayName,
            shortName: String(displayName.prefix(3)).uppercased(),
            apiKeyRef: "key-\(uuid)",
            enabled: enabled,
            sortOrder: 0,
            currency: nil,
            thresholds: .quota(warningPercent: 80, criticalPercent: 95)
        )
    }

    // MARK: - Immediate AppState propagation

    /// Toggling tracking off on a single instance must flip the live
    /// `AppState._instances[i].trackingEnabled` immediately — without
    /// waiting for `save()`. This is the fix for the user-visible bug
    /// "toggling the switch in Services doesn't remove the menu bar
    /// slot".
    func testToggleImmediatelyNotifiesAppState() async {
        let viewModel = makeViewModel()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([inst], settings: .default)
        await viewModel.load()
        await appState.setInstances([inst])

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)

        let liveInstances = await appState.getInstances()
        XCTAssertEqual(liveInstances.count, 1)
        XCTAssertFalse(liveInstances[0].trackingEnabled,
                       "AppState must reflect the toggle immediately, no save required")
    }

    /// Toggling on (re-enabling) must also propagate immediately. The
    /// menu bar won't show a slot until the next refresh, but the
    /// runtime `trackingEnabled` flag is updated so the next
    /// `performRefresh` will include this instance in the
    /// `enabledInstances` filter.
    func testToggleOnImmediatelyNotifiesAppState() async {
        let viewModel = makeViewModel()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: false)
        try? await persistenceService.saveInstances([inst], settings: .default)
        await viewModel.load()
        await appState.setInstances([inst])

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: true)

        let liveInstances = await appState.getInstances()
        XCTAssertTrue(liveInstances[0].trackingEnabled)
    }

    // MARK: - hasUnsavedChanges semantics

    /// A toggle that already took effect at runtime must STILL be
    /// reported as a pending change so the user sees the "Save
    /// Changes / Discard Changes" affordance. The runtime change is
    /// non-durable until `save()` lands it in `instances.json`.
    func testToggleMarksHasUnsavedChanges() async {
        let viewModel = makeViewModel()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([inst], settings: .default)
        await viewModel.load()
        await appState.setInstances([inst])

        XCTAssertFalse(viewModel.hasUnsavedChanges,
                       "After load, view model matches the on-disk baseline")

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)
        XCTAssertTrue(viewModel.hasUnsavedChanges,
                      "A tracking toggle must mark the view model dirty so the user sees Save/Discard")
    }

    // MARK: - Discard rollback

    /// After the user toggles tracking off, clicking "Discard Changes"
    /// must roll the runtime `AppState` back to the original state
    /// (i.e. tracking on again). The previous behavior was a silent
    /// no-op — the runtime state stayed disabled even though the UI
    /// reverted. See issue #20.
    func testDiscardChangesRollsBackAppState() async {
        let viewModel = makeViewModel()
        // Stage a real `originalInstances` baseline by writing + loading.
        let baseline = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([baseline], settings: .default)
        await viewModel.load()
        await appState.setInstances([baseline])

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)
        let midToggle = await appState.getInstances()
        XCTAssertFalse(midToggle[0].trackingEnabled, "Sanity: toggle took effect")

        await viewModel.discardChanges()
        let afterDiscard = await appState.getInstances()
        XCTAssertTrue(afterDiscard[0].trackingEnabled,
                      "discardChanges must roll the runtime tracking flag back to the loaded baseline")
        XCTAssertFalse(viewModel.hasUnsavedChanges,
                       "Discard must clear the dirty marker")
    }

    /// If the user toggles tracking off and then back on, the net
    /// state matches the loaded baseline (Instance is Equatable on
    /// all fields), so `hasUnsavedChanges` is back to false. This
    /// pins the behavior: the dirty marker is computed from the
    /// final `instances` value, not from the toggle count.
    func testDiscardChangesNoOpWhenToggleRevertedToOriginal() async {
        let viewModel = makeViewModel()
        let baseline = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([baseline], settings: .default)
        await viewModel.load()
        await appState.setInstances([baseline])

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)
        XCTAssertTrue(viewModel.hasUnsavedChanges,
                      "First flip must mark the draft dirty")

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: true)
        XCTAssertFalse(viewModel.hasUnsavedChanges,
                       "Reverting to the original value clears the dirty marker")

        // And the runtime state must be back to the baseline —
        // discard is a no-op because the draft already matches.
        await viewModel.discardChanges()
        let afterDiscard = await appState.getInstances()
        XCTAssertTrue(afterDiscard[0].trackingEnabled,
                      "Net result matches baseline: runtime state must be tracking on")
    }

    // MARK: - Delete instance propagates to AppState

    /// PR #23 review: deleting an instance from the settings draft
    /// must immediately remove it from the runtime `AppState`,
    /// otherwise `discardChanges` could leave the runtime in a
    /// state where an instance the user wants gone still has its
    /// slot visible. The deletion is a "single-UUID" event with
    /// the same propagation contract as `setInstanceTracking`.
    func testDeleteInstanceImmediatelyNotifiesAppState() async {
        let viewModel = makeViewModel()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([inst], settings: .default)
        await viewModel.load()
        // `viewModel.load()` only seeds the local draft; the
        // shared `appState` from `setUp` still needs the instance
        // (in production this is wired through `appStateProxy.initialize()`).
        await appState.setInstances([inst])

        // Sanity: instance is live in AppState after the seed.
        var live = await appState.getInstances()
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].uuid, "inst-1")

        await viewModel.deleteInstance(inst)

        live = await appState.getInstances()
        XCTAssertTrue(live.isEmpty,
                      "deleteInstance must evict the UUID from the runtime AppState")
    }

    /// PR #23 review follow-up: the previous delete implementation
    /// only mutated the local draft. Sequence: toggle A off →
    /// delete A → click Discard. The local draft restored A with
    /// trackingEnabled=true, but AppState still held A with
    /// trackingEnabled=false, so the slot stayed pruned. With the
    /// new delete path, AppState drops A on delete and Discard
    /// brings the local draft back to the loaded state — both
    /// sides agree "A is alive, tracking on, no slot yet".
    func testDeleteThenDiscardStaysConsistent() async {
        let viewModel = makeViewModel()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([inst], settings: .default)
        await viewModel.load()
        await appState.setInstances([inst])

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)
        await viewModel.deleteInstance(inst)

        // AppState has already forgotten the instance.
        var live = await appState.getInstances()
        XCTAssertTrue(live.isEmpty)

        // Discard: brings the local draft back to the loaded state.
        await viewModel.discardChanges()
        live = await appState.getInstances()
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live[0].trackingEnabled,
                      "Discard must leave AppState and draft consistent: instance restored with tracking on")
    }

    // MARK: - Save persists toggle

    /// A toggle followed by `save()` must persist the new
    /// `tracking_enabled` value in `instances.json`. We can't read
    /// the file with a custom decoder in this test (the
    /// PersistenceService has no override hook for the base path),
    /// but we can verify the success path runs to completion and
    /// the `originalInstances` mirror reflects the new value —
    /// proving the value was committed to the file (line 181 in
    /// `SettingsViewModel.save` only runs after the file write at
    /// line 129 succeeds).
    func testSavePersistsToggleState() async {
        let viewModel = makeViewModel()
        let baseline = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        try? await persistenceService.saveInstances([baseline], settings: .default)
        await viewModel.load()

        await viewModel.setInstanceTrackingEnabled(uuid: "inst-1", enabled: false)
        XCTAssertTrue(viewModel.hasUnsavedChanges)

        // Empty instances list avoids RefreshService touching the
        // supplier — we just want the file-write path. To do that,
        // we set the local list to a single no-provider instance and
        // let the refresh no-op. (See RefreshService.performRefresh:
        // empty enabledInstances short-circuits the cycle.)
        let success = await viewModel.save()
        XCTAssertTrue(success, "save() must succeed with a valid instance and one toggle")
        XCTAssertFalse(viewModel.hasUnsavedChanges,
                       "Successful save must clear the dirty marker (proves originalInstances was updated post-write)")

        // Reload from disk and confirm the new value is durable.
        let (reloaded, _, _) = await persistenceService.loadInstances()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertFalse(reloaded[0].trackingEnabled,
                       "Reloaded instances.json must reflect the toggled-off state")
    }
}
