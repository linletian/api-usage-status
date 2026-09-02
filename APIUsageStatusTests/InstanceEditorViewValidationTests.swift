import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for issue #20 — `InstanceEditorView`'s form
/// validation must allow saving an *existing* instance with no metrics
/// (so the user can pause tracking without deleting the
/// configuration), while still requiring at least one metric when
/// *creating* a new instance.
///
/// The validation logic is exposed via
/// `InstanceEditorView.evaluateFormState(...)` — a pure function the
/// instance computed properties (`isFormFilled`, `isAllMetricsDisabled`)
/// delegate to. We test the pure function directly because the
/// SwiftUI instance computed properties read `@State` defaults that
/// can't be observed from XCTest (and the @State values are private).
/// This is the same pattern `InstanceCardViewTests` uses to lock
/// SwiftUI struct behavior without rendering.
@MainActor
final class InstanceEditorViewValidationTests: XCTestCase {

    // MARK: - Fixtures

    private let validMetrics: [MetricConfig] = [
        MetricConfig(key: "minimax.general", group: "minimax", window: "5h", shortName: nil)
    ]
    private let validModelNames: [String] = ["minimax.general"]

    /// A typical MiniMax instance with one 5h metric. The form should
    /// be saveable as long as shortName and the metric list are valid.
    private func stage(
        selectedMetrics: [MetricConfig],
        shortName: String = "MX",
        isEditing: Bool = false,
        provider: Provider = .minimax,
        miniMaxModelNames: [String]? = nil
    ) -> (isFormFilled: Bool, isAllMetricsDisabled: Bool) {
        InstanceEditorView.evaluateFormState(
            provider: provider,
            selectedMetrics: selectedMetrics,
            shortName: shortName,
            isEditing: isEditing,
            miniMaxModelNames: miniMaxModelNames ?? validModelNames
        )
    }

    // MARK: - New instance: must require ≥ 1 metric

    /// A new instance with no metrics selected must NOT be
    /// saveable — otherwise we'd persist fully unconfigured entries.
    func testIsFormFilledRequiresMetricsForNew() {
        let state = stage(
            selectedMetrics: [],
            shortName: "MX",
            isEditing: false
        )
        XCTAssertFalse(state.isFormFilled,
                       "New instance with zero metrics must not be saveable")
        XCTAssertFalse(state.isAllMetricsDisabled,
                       "New-instance form is not 'editing' so the warning banner must not show")
    }

    /// A new instance with at least one metric and a valid shortName
    /// must be saveable. This is the baseline happy path and
    /// pre-dates the fix — we pin it so the relaxation below can't
    /// accidentally regress it.
    func testIsFormFilledAllowsPopulatedNew() {
        let state = stage(
            selectedMetrics: validMetrics,
            shortName: "MX",
            isEditing: false
        )
        XCTAssertTrue(state.isFormFilled,
                      "New instance with valid shortName + metrics must be saveable")
        XCTAssertFalse(state.isAllMetricsDisabled)
    }

    // MARK: - Edit instance: must allow empty metrics

    /// The core fix for the secondary symptom in issue #20: editing
    /// an existing instance with NO metrics must be saveable so the
    /// user can persist a paused state. The previous implementation
    /// required `!selectedMetrics.isEmpty` unconditionally, blocking
    /// this path.
    func testIsFormFilledAllowsEmptyMetricsForEdit() {
        let state = stage(
            selectedMetrics: [],
            shortName: "MX",
            isEditing: true
        )
        XCTAssertTrue(state.isFormFilled,
                      "Editing an instance with zero metrics must still be saveable " +
                      "so the user can persist the paused state (issue #20)")
        XCTAssertTrue(state.isAllMetricsDisabled,
                      "Editing with empty metrics must surface the warning banner")
    }

    /// Editing with at least one metric must remain the common,
    /// happy path. Pin against an accidental "always allow empty
    /// metrics" regression.
    func testIsFormFilledAllowsPopulatedEdit() {
        let state = stage(
            selectedMetrics: validMetrics,
            shortName: "MX",
            isEditing: true
        )
        XCTAssertTrue(state.isFormFilled,
                      "Editing an instance with valid metrics must remain saveable")
        XCTAssertFalse(state.isAllMetricsDisabled,
                       "The warning banner must NOT show when at least one metric is selected")
    }

    // MARK: - shortName still required regardless of metric count

    /// Even when editing, an invalid shortName keeps the form
    /// un-saveable. The edit-form relaxation only applies to the
    /// metric count, not to the other required fields.
    func testIsFormFilledStillRequiresShortName() {
        // Empty shortName — invalid.
        let emptyShortName = stage(
            selectedMetrics: validMetrics,
            shortName: "",
            isEditing: true
        )
        XCTAssertFalse(emptyShortName.isFormFilled,
                       "Empty shortName must keep the form unsaveable even in edit mode")

        // One-character shortName — also invalid.
        let oneCharShortName = stage(
            selectedMetrics: validMetrics,
            shortName: "M",
            isEditing: true
        )
        XCTAssertFalse(oneCharShortName.isFormFilled,
                       "Single-character shortName must keep the form unsaveable")

        // Four-character shortName — also invalid (max is 3).
        let tooLongShortName = stage(
            selectedMetrics: validMetrics,
            shortName: "MXAB",
            isEditing: true
        )
        XCTAssertFalse(tooLongShortName.isFormFilled,
                       "Four-character shortName must keep the form unsaveable")
    }

    /// New instance with empty shortName (even with metrics) must
    /// also fail — the shortName rule applies to both new and edit
    /// paths.
    func testIsFormFilledRequiresShortNameForNew() {
        let state = stage(
            selectedMetrics: validMetrics,
            shortName: "",
            isEditing: false
        )
        XCTAssertFalse(state.isFormFilled,
                       "New instance with empty shortName must not be saveable")
    }

    // MARK: - Banner visibility

    /// The warning banner is purely a function of (isEditing,
    /// selectedMetrics). It must surface ONLY in the edit-with-zero
    /// state and never in the new-instance or populated-edit paths.
    func testAllMetricsDisabledBannerOnlyShowsForEditWithEmptyMetrics() {
        // Edit, empty metrics → banner shows.
        let emptyEdit = stage(
            selectedMetrics: [], shortName: "MX", isEditing: true
        )
        XCTAssertTrue(emptyEdit.isAllMetricsDisabled)

        // Edit, populated → banner hidden.
        let populatedEdit = stage(
            selectedMetrics: validMetrics, shortName: "MX", isEditing: true
        )
        XCTAssertFalse(populatedEdit.isAllMetricsDisabled)

        // New instance, no metrics → banner hidden (the form isn't
        // even saveable — no need to warn about paused tracking).
        let newEmpty = stage(
            selectedMetrics: [], shortName: "MX", isEditing: false
        )
        XCTAssertFalse(newEmpty.isAllMetricsDisabled)

        // New instance, populated → banner hidden.
        let newPopulated = stage(
            selectedMetrics: validMetrics, shortName: "MX", isEditing: false
        )
        XCTAssertFalse(newPopulated.isAllMetricsDisabled)
    }

    // MARK: - MiniMax-no-model edge case

    /// When the MiniMax supplier has not yet returned any model
    /// names AND we're creating a new instance, the form lets the
    /// user save with a valid shortName alone — the metric list
    /// will be filled in once the supplier responds. The edit
    /// path is unaffected by this branch.
    func testMiniMaxNoModelShortCircuitForNew() {
        let newNoModels = stage(
            selectedMetrics: [],
            shortName: "MX",
            isEditing: false,
            provider: .minimax,
            miniMaxModelNames: []
        )
        XCTAssertTrue(newNoModels.isFormFilled,
                      "New MiniMax instance with no model list yet must be saveable with shortName alone")
    }
}
