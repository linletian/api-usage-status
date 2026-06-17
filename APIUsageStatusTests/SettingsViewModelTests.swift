import XCTest
@testable import APIUsageStatus

/// Tests for the sidebar / expansion behaviour added to `SettingsViewModel`.
///
/// The view-model is `@MainActor`, so every test must run on the main actor.
/// The class also depends on six services, but the tests below only exercise
/// the new local-state properties and the pure `toggleExpanded(uuid:)` method,
/// so the service instances are built just to satisfy the initializer —
/// none of them are ever invoked.
@MainActor
final class SettingsViewModelTests: XCTestCase {

    // MARK: - Default state

    /// A freshly initialised `SettingsViewModel` must expose an empty
    /// `expandedInstanceUUIDs` set. The view layer depends on this default
    /// to render every instance row collapsed on first appearance.
    func testExpandedInstanceUUIDsIsEmptyByDefault() {
        let viewModel = Self.makeViewModel()

        XCTAssertTrue(viewModel.expandedInstanceUUIDs.isEmpty)
    }

    /// The sidebar must default to the `services` tab on first appearance,
    /// which is where the user lands immediately after opening Settings.
    func testSelectedSidebarItemDefaultsToServices() {
        let viewModel = Self.makeViewModel()

        XCTAssertEqual(viewModel.selectedSidebarItem, .services)
    }

    // MARK: - toggleExpanded

    /// Toggling an unseen UUID adds it to the expansion set. This drives
    /// the disclosure indicator and the per-instance details panel.
    func testToggleExpandedAddsUUID() {
        let viewModel = Self.makeViewModel()
        let uuid = "instance-A"

        viewModel.toggleExpanded(uuid: uuid)

        XCTAssertTrue(viewModel.expandedInstanceUUIDs.contains(uuid))
        XCTAssertEqual(viewModel.expandedInstanceUUIDs.count, 1)
    }

    /// Toggling an already-expanded UUID removes it. This is the contract
    /// that turns a disclosure triangle into a collapse action.
    func testToggleExpandedRemovesUUID() {
        let viewModel = Self.makeViewModel()
        let uuid = "instance-B"
        viewModel.toggleExpanded(uuid: uuid)
        XCTAssertTrue(viewModel.expandedInstanceUUIDs.contains(uuid))

        viewModel.toggleExpanded(uuid: uuid)

        XCTAssertFalse(viewModel.expandedInstanceUUIDs.contains(uuid))
        XCTAssertTrue(viewModel.expandedInstanceUUIDs.isEmpty)
    }

    /// Toggling the same UUID twice yields the original state. This
    /// property is what keeps the disclosure UI predictable when the view
    /// re-renders during a parent state change.
    func testToggleExpandedIsIdempotent() {
        let viewModel = Self.makeViewModel()
        let uuid = "instance-C"

        viewModel.toggleExpanded(uuid: uuid)
        viewModel.toggleExpanded(uuid: uuid)

        XCTAssertFalse(viewModel.expandedInstanceUUIDs.contains(uuid))
        XCTAssertEqual(viewModel.expandedInstanceUUIDs.count, 0)
    }

    /// Multiple UUIDs can be expanded independently and simultaneously.
    /// The set semantics must not collapse or coalesce entries.
    func testMultipleUUIDsCanBeExpandedIndependently() {
        let viewModel = Self.makeViewModel()
        let uuids = ["alpha", "beta", "gamma"]

        for uuid in uuids {
            viewModel.toggleExpanded(uuid: uuid)
        }

        XCTAssertEqual(viewModel.expandedInstanceUUIDs.count, uuids.count)
        for uuid in uuids {
            XCTAssertTrue(
                viewModel.expandedInstanceUUIDs.contains(uuid),
                "Expected \(uuid) to be present in the expansion set"
            )
        }
    }

    // MARK: - Side effects

    /// Expansion state is a UI concern; it must not flip the
    /// `hasUnsavedChanges` flag that gates the Save button. A bug here
    /// would make every disclosure toggle dirty the document.
    func testToggleDoesNotAffectHasUnsavedChanges() {
        let viewModel = Self.makeViewModel()
        XCTAssertFalse(
            viewModel.hasUnsavedChanges,
            "A fresh view-model must report no unsaved changes"
        )

        viewModel.toggleExpanded(uuid: "x")
        viewModel.toggleExpanded(uuid: "y")
        viewModel.toggleExpanded(uuid: "y")

        XCTAssertFalse(
            viewModel.hasUnsavedChanges,
            "Expanding/collapsing rows must not mark the document dirty"
        )
    }

    // MARK: - SidebarItem

    /// `SidebarItem` must expose exactly three cases. A regression here
    /// would change the navigation structure surfaced in Settings.
    func testSidebarItemHasThreeCases() {
        XCTAssertEqual(SidebarItem.allCases.count, 3)
    }

    /// All `SidebarItem` cases must have distinct raw values — a
    /// `RawRepresentable` enum with duplicate raw values would collapse
    /// tab selection in the persisted UI state.
    func testSidebarItemCasesAreAllUnique() {
        let rawValues = SidebarItem.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(rawValues).count,
            rawValues.count,
            "SidebarItem raw values must be unique"
        )
    }

    // MARK: - Sidebar selection

    /// Switching `selectedSidebarItem` to `.general` must update the
    /// property so the view shows the General form.
    func testSelectedSidebarItemCanBeSetToGeneral() {
        let viewModel = Self.makeViewModel()
        viewModel.selectedSidebarItem = .general
        XCTAssertEqual(viewModel.selectedSidebarItem, .general)
    }

    /// Switching `selectedSidebarItem` to `.about` must update the
    /// property so the view shows the About panel.
    func testSelectedSidebarItemCanBeSetToAbout() {
        let viewModel = Self.makeViewModel()
        viewModel.selectedSidebarItem = .about
        XCTAssertEqual(viewModel.selectedSidebarItem, .about)
    }

    /// Switching back to `.services` after visiting another tab must
    /// restore the services list view.
    func testSelectedSidebarItemCanBeSetBackToServices() {
        let viewModel = Self.makeViewModel()
        viewModel.selectedSidebarItem = .general
        viewModel.selectedSidebarItem = .services
        XCTAssertEqual(viewModel.selectedSidebarItem, .services)
    }

    // MARK: - SidebarItem display properties

    /// Each `SidebarItem` must return a non-empty icon name for the
    /// sidebar row SF Symbol.
    func testSidebarItemIconNamesAreNonEmpty() {
        for item in SidebarItem.allCases {
            XCTAssertFalse(
                item.iconName.isEmpty,
                "SidebarItem.\(item.rawValue).iconName must not be empty"
            )
        }
    }

    /// Each `SidebarItem` must return a non-empty display name for the
    /// sidebar row label.
    func testSidebarItemDisplayNamesAreNonEmpty() {
        for item in SidebarItem.allCases {
            XCTAssertFalse(
                item.displayName.isEmpty,
                "SidebarItem.\(item.rawValue).displayName must not be empty"
            )
        }
    }

    // MARK: - Form bindings (via GlobalSettings)

    /// Changing `refreshIntervalMinutes` through the view-model's
    /// settings binding must be reflected in the property value.
    func testRefreshIntervalBinding() {
        let viewModel = Self.makeViewModel()
        viewModel.settings.refreshIntervalMinutes = 30
        XCTAssertEqual(viewModel.settings.refreshIntervalMinutes, 30)
    }

    /// Changing `colorMode` through the view-model's settings binding
    /// must be reflected in the property value.
    func testColorModeBinding() {
        let viewModel = Self.makeViewModel()
        viewModel.settings.colorMode = .color
        XCTAssertEqual(viewModel.settings.colorMode, .color)
    }

    /// Changing `launchAtLogin` through the view-model's settings binding
    /// must be reflected in the property value.
    func testLaunchAtLoginBinding() {
        let viewModel = Self.makeViewModel()
        viewModel.settings.launchAtLogin = true
        XCTAssertTrue(viewModel.settings.launchAtLogin)
    }

    /// Changing `notificationsEnabled` through the view-model's settings
    /// binding must be reflected in the property value.
    func testNotificationsEnabledBinding() {
        let viewModel = Self.makeViewModel()
        viewModel.settings.notificationsEnabled = false
        XCTAssertFalse(viewModel.settings.notificationsEnabled)
    }

    // MARK: - Helpers

    /// Build a `SettingsViewModel` wired to fresh, unused service stubs.
    /// None of the services are ever invoked by the tests in this file,
    /// so their state is irrelevant — they exist only to satisfy the
    /// required initializer signature.
    private static func makeViewModel() -> SettingsViewModel {
        let keychain = KeychainService()
        let persistence = PersistenceService(keychainService: keychain)
        let appState = AppState()
        let refresh = RefreshService(persistenceService: persistence, appState: appState)
        let appStateProxy = AppStateProxy(
            appState: appState,
            refreshService: refresh,
            persistenceService: persistence
        )
        let notifications = NotificationManager(openDetailPanel: { _ in })
        let launch = AppLaunchService()

        return SettingsViewModel(
            persistenceService: persistence,
            appState: appState,
            appStateProxy: appStateProxy,
            refreshService: refresh,
            notificationManager: notifications,
            appLaunchService: launch
        )
    }
}
