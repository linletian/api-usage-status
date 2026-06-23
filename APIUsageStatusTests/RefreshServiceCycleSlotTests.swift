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

    // MARK: - Shell process cancellation

    /// Cancelling the parent Task mid-shell-call must terminate the child
    /// process and return quickly. We use `/bin/sleep 30` with timeout 30
    /// (so the timeout would otherwise take 30s) and cancel after 50ms —
    /// the run should return in well under 2s via SIGTERM.
    func testShellProcessRunnerTerminatesOnParentCancellation() async throws {
        let runner = ShellProcessRunner.shared
        let cmd = ShellCommand(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeout: 30
        )

        let start = Date()
        let runnerTask = Task<Void, Error> {
            do {
                _ = try await runner.run(cmd)
                throw NSError(domain: "test", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "expected throw"])
            } catch is CancellationError {
                return
            } catch is ShellError {
                // SIGTERM surfaces as nonZeroExit / launchFailed before
                // cancellation propagates. Either way, the process must
                // have been terminated within the time bound.
                return
            } catch {
                // URLError / POSIX / NSError from terminated process are
                // also acceptable here.
                return
            }
        }
        // Give the process a chance to spawn, then cancel.
        try? await Task.sleep(for: .milliseconds(50))
        runnerTask.cancel()
        try await runnerTask.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0,
            "SIGTERM should kill the child well within 2s; took \(elapsed)s")
    }
}