import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for `AppState.mergeCycleResult`. The merge drives
/// the "show last successful data on refresh failure" UX: failed cycles
/// must preserve the cached slots and mark them `isStale=true`; successful
/// cycles must overwrite with fresh data (`isStale=false`); deleted
/// instances must be evicted. Staleness is reported via `slot.isStale`
/// only — `slot.colorState` always reflects the underlying threshold.
///
/// Concurrency contract under test: `mergeCycleResult` reads
/// `_instances` INSIDE the actor — callers don't pass a UUID snapshot,
/// so there is no TOCTOU window between the caller's `getInstances()`
/// and the merge.
final class AppStateMergeTests: XCTestCase {

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
        displayName: String,
        isStale: Bool = false
    ) -> SlotViewData {
        SlotViewData(
            uuid: uuid,
            displayName: displayName,
            shortName: String(displayName.prefix(3)).uppercased(),
            sortOrder: 0,
            colorState: .normal,
            provider: "test",
            dimension: "test",
            isStale: isStale
        )
    }

    private func isStale(uuid: String, in slots: [SlotViewData]) -> Bool {
        slots.first(where: { $0.uuid == uuid })?.isStale ?? false
    }

    private func colorState(uuid: String, in slots: [SlotViewData]) -> ColorState {
        slots.first(where: { $0.uuid == uuid })?.colorState ?? .loading
    }

    /// Seed `_instances` and run a merge with one successful cycle.
    private func seedAndSucceed(
        appState: AppState,
        instances: [Instance],
        slots: [SlotViewData]
    ) async {
        await appState.setInstances(instances)
        await appState.mergeCycleResult(
            cycleSuccesses: slots,
            cycleErroredUUIDs: []
        )
    }

    // MARK: - Tests

    /// A fully-failed cycle must preserve the existing slots and flip
    /// each remaining entry's `isStale=true`. Per docs/ARCHITECTURE.md
    /// §7.5, this is what makes the panel show the cached values in gray
    /// with a "Cached X ago" footer instead of "Unable to load".
    func testAllFailedPreservesCacheAndMarksStale() async {
        let appState = AppState()

        // Seed two instances + two slots (both fresh from a prior
        // successful cycle).
        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await seedAndSucceed(
            appState: appState,
            instances: [inst1, inst2],
            slots: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ]
        )

        // Now both fail this cycle. `mergeCycleResult` reads
        // `_instances` internally — still both alive, so the cached
        // slots are preserved but flagged stale.
        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: ["inst-1", "inst-2"]
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 2, "Failed cycle must not drop cached slots")
        XCTAssertTrue(isStale(uuid: "inst-1", in: slots),
                      "Failed cycle must mark cached slot stale (single source of truth)")
        XCTAssertTrue(isStale(uuid: "inst-2", in: slots))
        XCTAssertEqual(colorState(uuid: "inst-1", in: slots), .normal,
                       "Stale slot must preserve its original colorState (orthogonal fields)")
        XCTAssertEqual(colorState(uuid: "inst-2", in: slots), .normal)
    }

    /// A partial-success cycle overwrites the cached entry for the
    /// successful instance with fresh data (`isStale=false`); the failed
    /// instance keeps its previous cached slot, now marked stale.
    func testPartialFailureMergesAndMarksOnlyFailed() async {
        let appState = AppState()

        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await seedAndSucceed(
            appState: appState,
            instances: [inst1, inst2],
            slots: [
                makeSlot(uuid: "inst-1", displayName: "Old-Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Old-Beta"),
            ]
        )

        // inst-1 succeeds with fresh displayName, inst-2 fails.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "New-Alpha")],
            cycleErroredUUIDs: ["inst-2"]
        )

        let slots = await appState.getSlotViewDataList()
        let byUUID = Dictionary(uniqueKeysWithValues: slots.map { ($0.uuid, $0) })

        XCTAssertEqual(byUUID["inst-1"]?.displayName, "New-Alpha",
                       "Successful slot must replace cached entry")
        XCTAssertFalse(isStale(uuid: "inst-1", in: slots),
                       "Successfully refreshed slot must NOT be marked stale")

        XCTAssertEqual(byUUID["inst-2"]?.displayName, "Old-Beta",
                       "Failed slot must keep its previous cached data")
        XCTAssertTrue(isStale(uuid: "inst-2", in: slots),
                      "Failed slot must be marked stale")
        XCTAssertEqual(colorState(uuid: "inst-2", in: slots), .normal,
                       "Stale slot must preserve its original colorState (orthogonal fields)")
    }

    /// When an instance is removed from `_instances` BEFORE the merge,
    /// its cached slot must be evicted. This is the "user deleted an
    /// instance via Settings" path — the merge sees the updated list
    /// because it reads `_instances` inside the actor.
    func testRemovedInstanceEvictedFromCache() async {
        let appState = AppState()

        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await seedAndSucceed(
            appState: appState,
            instances: [inst1, inst2],
            slots: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ]
        )

        // User deletes inst-2 via the settings flow (which calls
        // `updateInstances` and so on). `_instances` now contains only
        // inst-1.
        await appState.setInstances([inst1])

        // Next refresh cycle succeeds for inst-1; inst-2 is gone.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.uuid, "inst-1",
                       "Deleted instance's cached slot must be evicted")
    }

    /// A new instance appearing for the first time is appended on its
    /// first successful fetch; existing cached entries are not disturbed.
    func testNewInstanceAppendsToCache() async {
        let appState = AppState()

        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        await appState.setInstances([inst1])
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: []
        )

        // User adds inst-2 via settings; next cycle fetches both.
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await appState.setInstances([inst1, inst2])
        await appState.mergeCycleResult(
            cycleSuccesses: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ],
            cycleErroredUUIDs: []
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 2)
        let uuids = Set(slots.map(\.uuid))
        XCTAssertEqual(uuids, ["inst-1", "inst-2"])
    }

    /// A slot that was previously marked stale should revert to fresh
    /// (`isStale=false`) once its instance succeeds again. The
    /// `colorState` is independent of `isStale` and stays at the
    /// underlying threshold throughout.
    func testStaleSlotRevertsToFreshOnRecovery() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        // Cycle 1: success.
        await seedAndSucceed(
            appState: appState,
            instances: [inst],
            slots: [makeSlot(uuid: "x", displayName: "X")]
        )

        // Cycle 2: failure — slot becomes stale.
        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: ["x"]
        )
        let afterFailure = await appState.getSlotViewDataList()
        XCTAssertTrue(isStale(uuid: "x", in: afterFailure),
                      "Failed cycle must mark slot stale")
        XCTAssertEqual(colorState(uuid: "x", in: afterFailure), .normal,
                       "Stale slot must preserve its original colorState (orthogonal fields)")

        // Cycle 3: success again — slot reverts to fresh.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "x", displayName: "X")],
            cycleErroredUUIDs: []
        )
        let afterRecovery = await appState.getSlotViewDataList()
        XCTAssertFalse(isStale(uuid: "x", in: afterRecovery),
                       "Successfully re-fetched slot must clear isStale")
        XCTAssertEqual(colorState(uuid: "x", in: afterRecovery), .normal,
                       "Stale->fresh transition keeps the same colorState (no .error involvement)")
    }

    // MARK: - Concurrency / robustness regression

    /// `mergeCycleResult` reads `_instances` INSIDE the actor, so the
    /// deleted-instance eviction is authoritative at merge time. To
    /// verify the no-TOCTOU guarantee concretely: simulate a delete
    /// happening between the previous successful cycle and the next
    /// merge. The merge should evict the deleted instance's cached
    /// slot because `_instances` no longer contains it — even though
    /// no caller passed a "current UUIDs" snapshot.
    func testDeletionBetweenCyclesIsAuthoritative() async {
        let appState = AppState()

        let inst1 = makeInstance(uuid: "inst-1", displayName: "Alpha")
        let inst2 = makeInstance(uuid: "inst-2", displayName: "Beta")
        await seedAndSucceed(
            appState: appState,
            instances: [inst1, inst2],
            slots: [
                makeSlot(uuid: "inst-1", displayName: "Alpha"),
                makeSlot(uuid: "inst-2", displayName: "Beta"),
            ]
        )

        // User deletes inst-2.
        await appState.setInstances([inst1])

        // Next cycle: inst-1 succeeds; inst-2 fails. We do NOT pass
        // any "current UUIDs" argument — the merge must consult
        // `_instances` itself.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "inst-1", displayName: "Alpha")],
            cycleErroredUUIDs: ["inst-2"]
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 1, "inst-2 must be evicted despite the merge not receiving a UUID snapshot")
        XCTAssertEqual(slots.first?.uuid, "inst-1")
    }

    // MARK: - Call-order / idempotency / overlap edges

    /// If the same UUID appears in BOTH `cycleSuccesses` and
    /// `cycleErroredUUIDs` (which shouldn't happen in normal operation
    /// but could result from a caller bug), the success path wins.
    /// Rationale: `cycleSuccesses` is the second dict insertion in the
    /// implementation; the stale flag then writes back over a now-fresh
    /// entry, but the entry's *data* is the fresh success slot, not
    /// the previous cached one. So the resulting slot has `isStale=true`
    /// but fresh data — defensible degraded behavior, not a crash.
    func testSameUuidInSuccessesAndErrorsSuccessPathWins() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        await seedAndSucceed(
            appState: appState,
            instances: [inst],
            slots: [makeSlot(uuid: "x", displayName: "Old")]
        )

        // Defensive: success slot has isStale=false by default.
        let newSlot = makeSlot(uuid: "x", displayName: "New")

        await appState.mergeCycleResult(
            cycleSuccesses: [newSlot],
            cycleErroredUUIDs: ["x"]
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 1)
        let entry = slots.first
        XCTAssertEqual(entry?.displayName, "New",
                       "Success slot data must win on UUID overlap")
        XCTAssertTrue(isStale(uuid: "x", in: slots),
                      "Stale flag still applies from the error path")
        XCTAssertEqual(colorState(uuid: "x", in: slots), .normal,
                       "Success slot's colorState wins on overlap; staleness is reported via isStale, not colorState")
    }

    /// Calling `mergeCycleResult` twice with identical inputs is a
    /// no-op the second time. The buffer should already be in the
    /// intended state from the first call.
    func testRepeatedMergeWithSameInputIsIdempotent() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        await seedAndSucceed(
            appState: appState,
            instances: [inst],
            slots: [makeSlot(uuid: "x", displayName: "X")]
        )

        let first = await appState.getSlotViewDataList()
        let firstFetchedAt = first.first?.lastFetchedAt

        // Apply the same failure twice.
        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: ["x"]
        )
        let afterFirst = await appState.getSlotViewDataList()

        // Wait a tick so any second-call refresh would change lastFetchedAt.
        try? await Task.sleep(nanoseconds: 10_000_000)

        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: ["x"]
        )
        let afterSecond = await appState.getSlotViewDataList()

        XCTAssertEqual(afterFirst.count, afterSecond.count)
        XCTAssertEqual(afterFirst.first?.displayName, afterSecond.first?.displayName)
        XCTAssertEqual(afterFirst.first?.lastFetchedAt, afterSecond.first?.lastFetchedAt,
                       "Failed-cycle merge must not mutate lastFetchedAt")
        XCTAssertEqual(firstFetchedAt, afterSecond.first?.lastFetchedAt)
    }

    /// `cycleSuccesses` containing duplicate UUIDs must NOT crash and
    /// must keep only the last entry (last-wins). Defensive against a
    /// caller bug where the same instance gets mapped twice.
    func testDuplicateUuidsInCycleSuccessesLastWins() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        await appState.setInstances([inst])

        // Caller bug: same UUID twice.
        await appState.mergeCycleResult(
            cycleSuccesses: [
                makeSlot(uuid: "x", displayName: "First"),
                makeSlot(uuid: "x", displayName: "Second"),
            ],
            cycleErroredUUIDs: []
        )

        let slots = await appState.getSlotViewDataList()
        XCTAssertEqual(slots.count, 1, "Duplicate successes must collapse to one entry")
        XCTAssertEqual(slots.first?.displayName, "Second",
                       "Last occurrence must win")
    }

    /// Two empty collections (`cycleSuccesses: []`,
    /// `cycleErroredUUIDs: []`) MUST be a no-op. The buffer should be
    /// preserved bit-for-bit — `lastFetchedAt`, `isStale`, everything.
    func testEmptyInputsIsNoOp() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        let seedSlot = makeSlot(uuid: "x", displayName: "X")
        await seedAndSucceed(
            appState: appState,
            instances: [inst],
            slots: [seedSlot]
        )

        let before = await appState.getSlotViewDataList()
        let beforeFetchedAt = before.first?.lastFetchedAt

        try? await Task.sleep(nanoseconds: 10_000_000)

        await appState.mergeCycleResult(
            cycleSuccesses: [],
            cycleErroredUUIDs: []
        )

        let after = await appState.getSlotViewDataList()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.displayName, "X")
        XCTAssertEqual(after.first?.lastFetchedAt, beforeFetchedAt,
                       "Empty merge must not touch lastFetchedAt")
        XCTAssertFalse(isStale(uuid: "x", in: after),
                       "Empty merge must not flip a fresh slot to stale")
    }

    /// Out-of-order cycle recovery: if the previous cycle was
    /// unsuccessful and the new cycle succeeds, the slot must end up
    /// fresh and the cached data replaced. Already covered by
    /// `testStaleSlotRevertsToFreshOnRecovery`; this variant additionally
    /// verifies that a SUCCESS-after-FAILURE sequence doesn't leave any
    /// leftover stale flag from a separate, prior stale cycle.
    func testSuccessAfterFailureClearsAllStaleness() async {
        let appState = AppState()

        let inst = makeInstance(uuid: "x", displayName: "X")
        await seedAndSucceed(
            appState: appState,
            instances: [inst],
            slots: [makeSlot(uuid: "x", displayName: "X")]
        )

        // Two failed cycles in a row.
        await appState.mergeCycleResult(cycleSuccesses: [], cycleErroredUUIDs: ["x"])
        await appState.mergeCycleResult(cycleSuccesses: [], cycleErroredUUIDs: ["x"])

        let afterTwoFailures = await appState.getSlotViewDataList()
        XCTAssertTrue(isStale(uuid: "x", in: afterTwoFailures),
                      "Two consecutive failures must keep isStale=true")
        XCTAssertEqual(colorState(uuid: "x", in: afterTwoFailures), .normal,
                       "Stale slot must preserve its original colorState (orthogonal fields)")

        // Now a successful cycle.
        await appState.mergeCycleResult(
            cycleSuccesses: [makeSlot(uuid: "x", displayName: "Fresh")],
            cycleErroredUUIDs: []
        )

        let afterRecovery = await appState.getSlotViewDataList()
        XCTAssertEqual(afterRecovery.first?.displayName, "Fresh")
        XCTAssertFalse(isStale(uuid: "x", in: afterRecovery),
                       "Success after multiple failures must clear isStale")
        XCTAssertEqual(colorState(uuid: "x", in: afterRecovery), .normal,
                       "Stale->fresh transition keeps the same colorState")
    }
}
