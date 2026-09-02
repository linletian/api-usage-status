import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for issue #20 — `AppState` must prune a slot when
/// the owning instance's `trackingEnabled` flips to `false`, in every
/// state-mutation path (`setInstanceTracking`, `setInstances`,
/// `mergeCycleResult`). Without this, toggling a tracking switch in
/// `Settings → Services` would leave the previous slot in the buffer and
/// the menu bar would keep rendering the disabled instance.
///
/// Concurrency: `AppState` is an actor, so these tests await each
/// mutation. The methods are intentionally non-`async throws` — no
/// `await` failures to catch — which keeps the assertions on the
/// end-state rather than the call shape.
final class AppStateTrackingToggleTests: XCTestCase {

    // MARK: - Fixtures

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

    private func makeSlot(
        uuid: String,
        displayName: String
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: displayName,
            shortName: String(displayName.prefix(3)).uppercased(),
            sortOrder: 0,
            colorState: .normal,
            provider: "test",
            dimension: "test"
        )
    }

    private func uuids(of slots: [SlotViewData]) -> Set<String> {
        Set(slots.map(\.uuid))
    }

    // MARK: - setInstanceTracking

    /// The most direct user-visible fix: toggling a switch off in the
    /// Services tab calls `setInstanceTracking(uuid:, enabled: false)`,
    /// which must remove that instance's slot from the buffer. The
    /// previous behavior kept the slot and the menu bar kept rendering
    /// it.
    func testSetInstanceTrackingFalseRemovesSlot() async {
        let appState = AppState()
        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await appState.setInstances([inst1, inst2])
        await appState.mergeCycleResult(
            cycleSuccesses: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ],
            cycleErroredUUIDs: []
        )

        let changed = await appState.setInstanceTracking(uuid: "inst-1", enabled: false)
        XCTAssertTrue(changed, "setInstanceTracking must report a state change when the flag flips")

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(uuids(of: slots), ["inst-2"],
                       "Disabled instance's slot must be pruned from the buffer")
        let instances = await appState.getInstances()
        XCTAssertFalse(instances.first(where: { $0.uuid == "inst-1" })!.trackingEnabled,
                       "Disabled instance's trackingEnabled must be flipped in the live instance list")
        XCTAssertTrue(instances.first(where: { $0.uuid == "inst-2" })!.trackingEnabled,
                      "Untouched instance's trackingEnabled must remain unchanged")
    }

    /// Toggling a previously-disabled instance back on does NOT
    /// pre-emptively create a slot — the slot is only created on the
    /// next successful refresh. The method must report "no change"
    /// (return false) when the flag is already in the requested state,
    /// so callers can decide whether to log or trigger work.
    func testSetInstanceTrackingTrueOnDisabledKeepsInstanceNoSlot() async {
        let appState = AppState()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: false)
        await appState.setInstances([inst])

        let changed = await appState.setInstanceTracking(uuid: "inst-1", enabled: true)
        XCTAssertTrue(changed, "Flag must flip when previous state was different")

        let slots = await appState.getSlotViewDataList()
        XCTAssertTrue(slots.isEmpty,
                      "Re-enabling must NOT create a slot; the next refresh rebuilds it")

        let instances = await appState.getInstances()
        XCTAssertTrue(instances.first!.trackingEnabled)
    }

    /// Calling `setInstanceTracking` with the same value as the current
    /// state is a no-op and must return `false`. The slot buffer is
    /// untouched either way — but the boolean lets callers avoid
    /// re-triggering side effects (e.g. logging, refresh).
    func testSetInstanceTrackingNoOpWhenAlreadyInState() async {
        let appState = AppState()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        await appState.setInstances([inst])
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        let changed = await appState.setInstanceTracking(uuid: "inst-1", enabled: true)
        XCTAssertFalse(changed, "Setting the same value must report no change")

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(uuids(of: slots), ["inst-1"],
                       "No-op toggle must not disturb the slot buffer")
    }

    /// A UUID that doesn't exist in `_instances` is a silent no-op —
    /// `setInstanceTracking` returns `false` and the slot buffer is
    /// untouched. Defensive: a stale UI event racing a delete should
    /// not crash or write through.
    func testSetInstanceTrackingUnknownUuidIsNoOp() async {
        let appState = AppState()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha")
        await appState.setInstances([inst])
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        let changed = await appState.setInstanceTracking(uuid: "ghost", enabled: false)
        XCTAssertFalse(changed, "Unknown UUID must not report a change")

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(uuids(of: slots), ["inst-1"],
                       "Unknown UUID must not disturb the slot buffer")
    }

    // MARK: - setInstances

    /// `setInstances` is called from `SettingsViewModel.save()` after
    /// the user commits a batch edit. If the new list contains a
    /// disabled instance whose slot was previously cached, that slot
    /// must be pruned — otherwise the menu bar would still show it
    /// after save.
    func testSetInstancesFiltersDisabledSlots() async {
        let appState = AppState()
        let inst1Enabled = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        let inst2Disabled = makeInstance(uuid: "inst-2", displayName: "Beta", enabled: false)
        await appState.setInstances([inst1Enabled, inst2Disabled])
        // Pretend both have cached slots already.
        await appState.mergeCycleResult(
            cycleSuccesses: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ],
            cycleErroredUUIDs: []
        )

        // Re-write the same list (simulates `save()` rewriting the
        // post-toggle list). The disabled instance's slot must drop
        // from the buffer.
        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(uuids(of: slots), ["inst-1"],
                       "setInstances must prune slots for any instance with trackingEnabled=false")
    }

    // MARK: - mergeCycleResult

    /// A tracking toggle that flips to `false` between cycle start and
    /// merge must not be re-introduced by the supplier's fresh
    /// `cycleSuccesses` entry. The trailing `pruneDisabledSlots()` pass
    /// inside `mergeCycleResult` is what enforces this — without it,
    /// the success path's `byUUID[uuid] = slot` would re-add the
    /// disabled instance.
    func testMergeCycleResultFiltersDisabledSlots() async {
        let appState = AppState()
        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta", enabled: true)
        await appState.setInstances([inst1, inst2])

        // User toggles inst-2 off mid-cycle.
        await appState.setInstanceTracking(uuid: "inst-2", enabled: false)

        // Supplier hands back a fresh success slot for inst-2 (it
        // doesn't know the user paused it). Merge must drop it.
        await appState.mergeCycleResult(
            cycleSuccesses: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ],
            cycleErroredUUIDs: []
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(uuids(of: slots), ["inst-1"],
                       "mergeCycleResult must drop slots for instances that became disabled mid-cycle")
    }

    /// An error UUID belonging to a now-disabled instance is also
    /// pruned. The error path's `byUUID[uuid] = slot` is not even
    /// reached for a buffer without a pre-existing slot, but if one
    /// was carried over from a previous cycle the trailing prune
    /// removes it.
    func testMergeCycleResultErrorOnDisabledInstanceDropsSlot() async {
        let appState = AppState()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        await appState.setInstances([inst])
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        // User toggles off.
        await appState.setInstanceTracking(uuid: "inst-1", enabled: false)

        // Next cycle fails for inst-1. Even with the errored UUID
        // explicitly listed, the trailing prune drops the slot.
        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: ["inst-1"]
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertTrue(slots.isEmpty,
                      "A failure-cycle merge must not re-introduce a disabled instance's slot")
    }

    // MARK: - End-to-end: toggle off → on → refresh

    /// Full lifecycle: toggle off, then back on, then a successful
    /// cycle. The slot must reappear with fresh data. This is the
    /// scenario the user actually exercises when they re-enable an
    /// instance after temporarily pausing it.
    func testReenableKeepsInstanceVisibleAfterRefresh() async {
        let appState = AppState()
        let inst = makeInstance(uuid: "inst-1", displayName: "Alpha", enabled: true)
        await appState.setInstances([inst])
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        // 1. Toggle off — slot gone.
        await appState.setInstanceTracking(uuid: "inst-1", enabled: false)
        var slots = await appState.getSlotViewDataList()
        XCTAssertTrue(slots.isEmpty, "Slot must be pruned on disable")

        // 2. Toggle back on — no slot yet (waiting for next cycle).
        await appState.setInstanceTracking(uuid: "inst-1", enabled: true)
        slots = await appState.getSlotViewDataList()
        XCTAssertTrue(slots.isEmpty, "Re-enable must not synthesize a slot")

        // 3. Next successful cycle rebuilds the slot.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha-Refreshed")],
            cycleErroredUUIDs: []
        )
        slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.displayName, "Alpha-Refreshed",
                       "Post-enable refresh must rebuild the slot with fresh data")
    }
}
