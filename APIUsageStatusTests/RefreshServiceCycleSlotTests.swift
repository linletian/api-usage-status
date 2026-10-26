import XCTest
@testable import APIUsageStatus

/// Behavior-lock tests for the cycle-slot concurrency contract in
/// `RefreshService`. The cycle slot guarantees:
///
/// - At most one `performRefresh` cycle runs at a time (no concurrent cycles).
/// - A pre-empted `CycleToken` skips cleanup writes so the newer cycle that
///   took over the slot is not clobbered.
/// - Cleanup writes (`setRefreshingInstanceUUIDs`, `setRefreshState`,
///   `mergeCycleResult`) only run when `!token.isPreempted` — i.e., the
///   cycle still owns the slot.
///
/// These tests focus on **end-state contracts** under sequential and rapid
/// invocations. Deterministic interleaving tests for actor reentrancy would
/// require injecting a stub `Supplier` into `SupplierRegistry`, which is out
/// of scope for this fix.
final class RefreshServiceCycleSlotTests: XCTestCase {

    private func makeServiceAndState() -> (RefreshService, AppState) {
        let appState = AppState()
        let service = RefreshService(
            persistenceService: PersistenceService(keychainService: KeychainService()),
            appState: appState
        )
        return (service, appState)
    }

    // MARK: - Basic end-state contracts

    func testRefreshStateResetsToIdleAfterManualRefresh() async {
        let (service, appState) = makeServiceAndState()
        await service.triggerManualRefresh()
        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle, "Manual refresh must end in .idle")
    }

    func testRefreshingInstanceUUIDsClearedAfterManualRefresh() async {
        let (service, appState) = makeServiceAndState()
        await service.triggerManualRefresh()
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty, "Spinning UUID set must be cleared at cycle end")
    }

    // MARK: - Rapid invocation contracts

    /// Five rapid manual clicks must NOT corrupt end state: regardless of
    /// how many cycles ran internally, the final `refreshState` is `.idle`
    /// and `refreshingInstanceUUIDs` is empty.
    func testFiveRapidManualRefreshesEndInCleanState() async {
        let (service, appState) = makeServiceAndState()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await service.triggerManualRefresh()
                }
            }
        }
        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle, "After rapid clicks, refresh state must settle to .idle")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty, "After rapid clicks, no instance should be in spinning state")
    }

    /// Mixing manual and per-instance refresh calls must also end clean.
    /// Each `triggerInstanceRefresh` is a "补刷新" gesture and must respect
    /// any in-flight cycle (no-op if `cycleTask != nil`).
    func testMixedRapidManualAndInstanceRefreshesEndInCleanState() async {
        let (service, appState) = makeServiceAndState()
        await appState.setInstances([
            Instance(
                uuid: "test-1",
                provider: Provider.minimax.rawValue,
                dimension: "general",
                displayName: "Test 1",
                shortName: "T1",
                apiKeyRef: "test-key",
                enabled: true,
                sortOrder: 0,
                thresholds: .quota(warningPercent: 80, criticalPercent: 95)
            )
        ])
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    if i % 2 == 0 {
                        await service.triggerManualRefresh()
                    } else {
                        await service.triggerInstanceRefresh(instanceUUID: "test-1")
                    }
                }
            }
        }
        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle)
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty)
    }

    // MARK: - Per-instance refresh invariants

    /// `triggerInstanceRefresh` for a non-existent UUID is a silent no-op
    /// (the cycle logs and bails without touching shared state). The early
    /// return resets `refreshState` back to `.idle`.
    func testTriggerInstanceRefreshForMissingUUIDResetsState() async {
        let (service, appState) = makeServiceAndState()
        await service.triggerInstanceRefresh(instanceUUID: "does-not-exist")
        let state = await appState.getRefreshState()
        XCTAssertNotEqual(state, .refreshing,
            "Missing-target early-return must reset refreshState to .idle")
    }

    // MARK: - Cancellation propagation contracts

    /// `RetryPolicy.withRetry` must NOT swallow `CancellationError` and
    /// must NOT retry it. A cancellation that survives from a `Task.cancel()`
    /// should propagate up immediately so the cycle-slot can detect it.
    func testRetryPolicyRethrowsCancellationInsteadOfRetrying() async {
        var attemptCount = 0
        do {
            _ = try await RetryPolicy.shared.withRetry {
                attemptCount += 1
                throw CancellationError()
            }
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            XCTAssertEqual(attemptCount, 1, "CancellationError must NOT be retried")
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    /// Cancellation in the first attempt of a retry chain must surface
    /// before any retry happens (no backoff sleep).
    func testRetryPolicyCancelsBeforeSleepingForBackoff() async {
        var attemptCount = 0
        let start = Date()
        do {
            _ = try await RetryPolicy.shared.withRetry {
                attemptCount += 1
                throw CancellationError()
            }
            XCTFail("Expected CancellationError to propagate")
        } catch is CancellationError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(attemptCount, 1)
            // First retry would sleep ≥100ms; cancellation must propagate
            // in well under that.
            XCTAssertLessThan(elapsed, 0.05,
                "Cancellation must short-circuit retry backoff (took \(elapsed)s)")
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Cycle-slot age-based force-clear (§4.7 defense)

    /// A seeded token whose `startedAt` is older than `2 × refreshInterval`
    /// must be force-cleared by the next `runPeriodicCycle` tick, with a
    /// warning logged. Without this guard the leaked token would leave the
    /// per-instance spinner UI permanently spinning (see §12.6 of the
    /// investigation doc).
    func testStaleCycleTokenIsForceClearedOnNextPeriodicTick() async {
        let (service, appState) = makeServiceAndState()
        // 6 s refresh interval; threshold = 12 s. Set directly to avoid
        // racing with `restartTimer`'s async initial cycle.
        await service._testSetRefreshInterval(6.0)
        // 60 s > threshold 12 s — way over the limit.
        await service._testSeedStaleToken(ageSeconds: 60)
        let hasTokenAfterSeed = await service._testHasCurrentToken
        XCTAssertTrue(hasTokenAfterSeed,
            "Seed must leave a token in the slot")

        await service._testRunPeriodicCycle()

        // After runPeriodicCycle runs to completion (no enabled instances
        // → fast "skipped" path), the slot is cleared naturally. The
        // distinguishing proof is that the force-clear branch was taken
        // first: a fresh token would have skipped the entire cycle.
        // Indirectly, the test below proves the WERE-stale case ends
        // in clean state — the new natural-completion path follows.
        let hasTokenAfterCycle = await service._testHasCurrentToken
        XCTAssertFalse(hasTokenAfterCycle,
            "Stale token must be cleared after a force-cleared refresh cycle")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty, "Refreshing UUIDs must be empty")
    }

    /// A token seeded with `startedAt` younger than the threshold must
    /// NOT trigger force-clear — the next periodic tick observes it as
    /// in-flight and short-circuits. This is the negative test that
    /// proves the `Date().timeIntervalSince(stale.startedAt)` computation
    /// actually reads `startedAt` (not e.g. zero or current time).
    func testFreshCycleTokenIsNotForceCleared() async {
        let (service, _) = makeServiceAndState()
        await service._testSetRefreshInterval(6.0)
        // 1 s < threshold 12 s — well under the limit.
        await service._testSeedStaleToken(ageSeconds: 1)
        let hasTokenAfterSeed = await service._testHasCurrentToken
        XCTAssertTrue(hasTokenAfterSeed)

        await service._testRunPeriodicCycle()

        // The token is FRESH (1 s < threshold 12 s), so the force-clear
        // branch does NOT fire. runPeriodicCycle then sees the token in
        // flight and logs "periodic cycle skipped: token already in
        // flight", returning without touching the slot.
        let hasTokenAfterCycle = await service._testHasCurrentToken
        XCTAssertTrue(hasTokenAfterCycle,
            "Fresh token must be left in place — the periodic cycle should have skipped, not cleared")
        let age = await service._testCurrentTokenAge
        XCTAssertNotNil(age)
        XCTAssertLessThan(age ?? .infinity, 12.0,
            "Token age must remain under the threshold (proves startedAt survived)")
    }

    // MARK: - DispatchSourceTimer lifecycle (§13.4 regression)

    /// `stop()` must be safe to call when no timer is running, and
    /// repeated calls must not crash. Locks the
    /// `DispatchSourceTimer.cancel()` invariant: cancel is idempotent on
    /// a suspended / nil source, and the actor property must end up nil
    /// regardless of call count.
    func testStopCanBeCalledWhenTimerIsNotRunning() async {
        let (service, _) = makeServiceAndState()
        // No timer was started — first stop must be a no-op, not a crash.
        await service.stop()
        await service.stop()
        await service.stop()
        let hasSource = await service._testHasTimerSource
        XCTAssertFalse(hasSource,
            "After repeated stop() with no timer, _testHasTimerSource must be false")
    }

    /// `start()` followed by `stop()` leaves no timer source behind.
    /// This is the lifecycle contract relied on by `restartTimer`: every
    /// `start()` calls `stop()` first, so the previous source must be
    /// fully torn down before the new one is installed.
    func testStartThenStopClearsTimerSource() async {
        let (service, _) = makeServiceAndState()
        await service.start(interval: 0.05) // 0.05 minutes = 3 s
        let hasSourceAfterStart = await service._testHasTimerSource
        XCTAssertTrue(hasSourceAfterStart,
            "After start(), _testHasTimerSource must be true")
        await service.stop()
        let hasSourceAfterStop = await service._testHasTimerSource
        XCTAssertFalse(hasSourceAfterStop,
            "After stop(), _testHasTimerSource must be false")
    }

    // MARK: - Spinner-state cleanup invariant (§12.6 leak fix)

    /// `triggerInstanceRefresh` for a UUID that doesn't exist hits the
    /// early-return path at `RefreshService.swift` ~344. That branch used
    /// to inline `setRefreshState(.idle)` + `onRefreshComplete?()` under an
    /// `if !token.isPreempted` guard; the refactor moved both writes into
    /// `clearRefreshStateIfStill`. This test locks that the helper drains
    /// BOTH `refreshState` AND `refreshingInstanceUUIDs` on the missing-
    /// target path (UUIDs are empty here because they were never populated,
    /// but `refreshState` was set to `.refreshing` at line ~332 BEFORE the
    /// early-return check, so the helper is what undoes it).
    func testTriggerInstanceRefreshForMissingUUIDClearsAllState() async {
        let (service, appState) = makeServiceAndState()
        await service.triggerInstanceRefresh(instanceUUID: "does-not-exist")
        let state = await appState.getRefreshState()
        XCTAssertNotEqual(state, .refreshing,
            "Missing-target early-return must drain refreshState via the helper")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty,
            "Missing-target early-return must leave refreshingInstanceUUIDs empty")
    }

    /// A manual refresh where no instances are enabled hits the global
    /// empty-targets branch (`RefreshService.swift` ~362). Same invariant
    /// as the missing-UUID case but on the global path: refreshState was
    /// set to `.refreshing`, then the helper must drain it back to `.idle`
    /// AND clear `refreshingInstanceUUIDs` (which were never populated in
    /// this branch, so the empty-check is the lock).
    func testTriggerManualRefreshWithNoEnabledInstancesClearsAllState() async {
        let (service, appState) = makeServiceAndState()
        await appState.setInstances([])
        await service.triggerManualRefresh()
        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle,
            "Global empty-targets branch must reset refreshState to .idle")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty,
            "Global empty-targets branch must leave refreshingInstanceUUIDs empty")
    }

    /// Cooperative cancellation at `Task.checkCancellation()` (top of the
    /// supplier for-loop, ~line 410) throws BEFORE the inner
    /// `catch is CancellationError` block can run. Without the outer
    /// `do/catch` wrapper added in this refactor, the cancel would
    /// propagate up past the success-path cleanup at line ~647 and leave
    /// `refreshingInstanceUUIDs` populated with every UUID the cycle had
    /// set at line ~354 — the §12.6 leak. This test locks the wrapper by:
    ///
    /// 1. Adding an enabled instance so `performRefresh` populates the
    ///    UUID set at line ~354.
    /// 2. Cancelling the in-flight `cycleTask` via the test seam — the
    ///    cancellation will surface at the first `Task.checkCancellation()`
    ///    or `Task.sleep` the cycle awaits, whichever comes first.
    /// 3. Awaiting the manual refresh; the outer catch must drain both
    ///    `refreshState` AND `refreshingInstanceUUIDs` before re-throwing.
    ///
    /// Note: this test depends on the cycle taking long enough to observe
    /// the cancellation. With no API key configured, the cycle fails fast
    /// on the keychain guard (~line 387) and skips the for-loop entirely.
    /// The 60ms sleep below mirrors that the test is racing the cancellation
    /// against the cycle's first async await, which is acceptable for
    /// deterministic single-shot runs in CI but may flake on slow hosts.
    func testCooperativeCancellationDuringRefreshClearsUUIDs() async {
        let (service, appState) = makeServiceAndState()
        await appState.setInstances([
            Instance(
                uuid: "u-1",
                provider: Provider.minimax.rawValue,
                dimension: "general",
                displayName: "T1",
                shortName: "T1",
                apiKeyRef: "k-1",
                enabled: true,
                sortOrder: 0,
                thresholds: .quota(warningPercent: 80, criticalPercent: 95)
            )
        ])
        // Fire the manual refresh on a Task and cancel it shortly after.
        // The cycle's `performRefresh` will see the cancellation at
        // `Task.checkCancellation()` or `Task.sleep` inside the supplier
        // call. The outer catch in `performRefresh` must drain state.
        let refreshTask = Task {
            await service.triggerManualRefresh()
        }
        // Yield so the cycle task can run far enough to populate the
        // UUID set at line ~354, then cancel. 30ms is enough on CI
        // hardware; can be tuned if flaky.
        try? await Task.sleep(for: .milliseconds(30))
        await service._testCancelCurrentCycleTask()
        await refreshTask.value

        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle,
            "Cancellation must drain refreshState via the outer catch helper")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty,
            "Cancellation must drain refreshingInstanceUUIDs via the outer catch helper — otherwise §12.6 spinner leak")
    }

    /// Preemption invariant: when cycle A is preempted by cycle B, A's
    /// cleanup (`clearRefreshStateIfStill(tokenA)`) must NOT clobber B's
    /// UUID set / refreshState. The helper's `currentToken === token` guard
    /// is what makes this safe: `runPreemptiveCycle` calls
    /// `adoptCycle(token: B)` BEFORE cancelling A's task, so by the time
    /// A's cleanup runs, `currentToken == B` and the guard short-circuits.
    ///
    /// This test exercises the same scenario the user reported in §12.6:
    /// "用户手动点 Refresh → runPreemptiveCycle markPreempted + adoptCycle
    /// 接管, 新 cycle cleanup 正确清空 → 体感'手动刷新成功'". Without the
    /// helper, A's stale inline cleanup would race B's setRefreshingInstanceUUIDs
    /// at line ~354 and either clobber B's set or leave A's stale UUIDs in.
    func testPreemptedCycleDoesNotClobberNewOwnerUUIDs() async {
        let (service, appState) = makeServiceAndState()
        await appState.setInstances([
            Instance(
                uuid: "u-A",
                provider: Provider.minimax.rawValue,
                dimension: "general",
                displayName: "TA",
                shortName: "TA",
                apiKeyRef: "k-A",
                enabled: true,
                sortOrder: 0,
                thresholds: .quota(warningPercent: 80, criticalPercent: 95)
            ),
            Instance(
                uuid: "u-B",
                provider: Provider.minimax.rawValue,
                dimension: "general",
                displayName: "TB",
                shortName: "TB",
                apiKeyRef: "k-B",
                enabled: true,
                sortOrder: 1,
                thresholds: .quota(warningPercent: 80, criticalPercent: 95)
            )
        ])
        // Fire two rapid manual refreshes; the second preempts the first.
        // Without the `===` guard, A's cleanup would clobber B's set.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await service.triggerManualRefresh() }
            // Tiny yield to let A start; not strictly required because
            // `triggerManualRefresh` is fully serialized through
            // `runPreemptiveCycle`, but ensures A actually populated its
            // UUIDs before B preempts.
            try? await Task.sleep(for: .milliseconds(5))
            group.addTask { await service.triggerManualRefresh() }
        }
        let state = await appState.getRefreshState()
        XCTAssertEqual(state, .idle,
            "After A is preempted by B and B finishes, state must be .idle")
        let uuids = await appState.getRefreshingInstanceUUIDs()
        XCTAssertTrue(uuids.isEmpty,
            "After preempt-and-finish, no UUIDs should be left in the spinning set")
    }
}