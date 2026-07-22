import Foundation

/// Detects limit-cycle rollovers between two consecutive refresh snapshots.
///
/// The detection signal is a **jump-up** in `cycleRemainingSeconds` for the
/// same `(instanceUUID, metricKey)` pair, exceeding
/// `rolloverThresholdSeconds`. A normal refresh observes `remaining` decrease
/// monotonically by roughly the refresh interval; a cycle rollover (5h rolling
/// window, weekly/monthly boundary) makes `remaining` jump from near-zero to
/// approximately a full window length.
///
/// Why not `newCycleEndTime < oldCycleEndTime`?
/// Rolling 5h windows always have `cycleEndTime ≈ now + 5h`, so each refresh
/// reports an end time *later* than the previous one. That signal would never
/// fire on rolling windows, which is the common case for MiniMax, OpenCode,
/// and Kimi. The remaining-seconds jump signal works for both rolling and
/// fixed-schedule windows.
///
/// Pure: no I/O, no `Date()`, no `UNUserNotificationCenter`. Easy to unit
/// test by feeding two synthetic `[SlotViewData]` arrays.
struct LimitRolloverDetector {

    struct RolledMetric: Equatable {
        let metricKey: String
        let window: String?
        let newPercent: Double
        let cycleEndTime: Date?
    }

    struct DetectedRollover: Equatable {
        let instanceUUID: String
        let instanceDisplayName: String
        let instanceShortName: String
        let rolledMetrics: [RolledMetric]
    }

    /// Compare `oldSlots` (last successful refresh) with `newSlots` (just
    /// completed refresh) and return one `DetectedRollover` per instance that
    /// had at least one metric roll over. `lastFired` is the per-key
    /// `cycleEndTime` of the most recent notification; entries whose new
    /// `cycleEndTime` is not strictly greater than `lastFired` are skipped to
    /// avoid re-firing within the same cycle.
    ///
    /// `refreshIntervalSeconds` drives the rollover-detection threshold
    /// (see `rolloverThreshold(forRefreshInterval:)`): the threshold must be
    /// strictly larger than the refresh interval itself, otherwise a single
    /// late or noisy refresh tick could be misclassified as a rollover.
    ///
    /// Disabled instances (`instance.enabled == false`) are ignored so a
    /// paused instance can't fire a stale notification. Snapshots whose
    /// `window == nil` (e.g. DeepSeek balance) are ignored — they don't have
    /// a cycle to roll over.
    static func detect(
        oldSlots: [SlotViewData],
        newSlots: [SlotViewData],
        instances: [Instance],
        lastFired: [String: Date],
        refreshIntervalSeconds: Int
    ) -> [String: DetectedRollover] {

        let threshold = rolloverThreshold(forRefreshInterval: refreshIntervalSeconds)
        let oldByKey = indexSlotsByInstanceMetricKey(oldSlots)
        let instanceByUUID = Dictionary(uniqueKeysWithValues: instances.map { ($0.uuid, $0) })

        // Working buffer keyed by instanceUUID. We carry the display fields
        // forward as soon as we add the first rolled metric so the final
        // mapValues pass can reconstruct the public `DetectedRollover` shape
        // without re-scanning instances.
        var aggregated: [String: (info: DetectedRollover, metrics: [RolledMetric])] = [:]

        for newSlot in newSlots {
            guard let instance = instanceByUUID[newSlot.uuid] else { continue }
            guard instance.enabled else { continue }

            for newSnap in newSlot.metricSnapshots where newSnap.window != nil {
                let key = "\(newSlot.uuid):\(newSnap.key)"
                let oldSnap = oldByKey[key]
                let oldRemaining = oldSnap?.cycleRemainingSeconds

                // Both sides must report remaining seconds; nil on either
                // side is treated as "indeterminate" and we skip rather
                // than risk a false positive.
                guard let newRemaining = newSnap.cycleRemainingSeconds,
                      let oldRemaining else { continue }

                // The detection signal: remaining time jumped forward by
                // more than the threshold. Normal refreshes see remaining
                // *decrease* by roughly the refresh interval; a rollover
                // sees it jump back up to nearly a full window.
                let delta = newRemaining - oldRemaining
                guard delta > threshold else { continue }

                // Dedupe: if we already fired for this (instance, metric)
                // at this cycle's end time (or later), don't fire again.
                // Skip silently when newEnd is nil — that's a malformed
                // rollover (remaining jumped but end time missing); we
                // already saw `cycleRemainingSeconds` so the threshold
                // check passed, but without an end time we can't dedupe.
                if let lastEnd = lastFired[key],
                   let newEnd = newSnap.cycleEndTime,
                   newEnd <= lastEnd {
                    continue
                }

                let rolled = RolledMetric(
                    metricKey: newSnap.key,
                    window: newSnap.window,
                    newPercent: newSnap.percent,
                    cycleEndTime: newSnap.cycleEndTime
                )

                if var existing = aggregated[newSlot.uuid] {
                    existing.metrics.append(rolled)
                    aggregated[newSlot.uuid] = existing
                } else {
                    aggregated[newSlot.uuid] = (
                        info: DetectedRollover(
                            instanceUUID: newSlot.uuid,
                            instanceDisplayName: newSlot.displayName,
                            instanceShortName: newSlot.shortName,
                            rolledMetrics: []
                        ),
                        metrics: [rolled]
                    )
                }
            }
        }

        return aggregated.mapValues { entry in
            DetectedRollover(
                instanceUUID: entry.info.instanceUUID,
                instanceDisplayName: entry.info.instanceDisplayName,
                instanceShortName: entry.info.instanceShortName,
                rolledMetrics: entry.metrics
            )
        }
    }

    /// Minimum jump (seconds) in `cycleRemainingSeconds` to count as a rollover.
    /// Must be **strictly greater than `refreshIntervalSeconds`** — a normal
    /// refresh sees `remaining` decrease by roughly the interval, so anything
    /// within `±refreshInterval` is the expected noise floor. Anything beyond
    /// that is a rollover. Floor of 60 s covers the theoretical case where
    /// `refreshIntervalSeconds` is 0 (timer-driven detection with no scheduled
    /// interval) — better a noisy threshold than a divide-by-zero trap.
    static func rolloverThreshold(forRefreshInterval refreshIntervalSeconds: Int) -> Int {
        max(60, refreshIntervalSeconds + 30)
    }

    private static func indexSlotsByInstanceMetricKey(_ slots: [SlotViewData]) -> [String: MetricSnapshot] {
        var dict: [String: MetricSnapshot] = [:]
        for slot in slots {
            for snap in slot.metricSnapshots where snap.window != nil {
                dict["\(slot.uuid):\(snap.key)"] = snap
            }
        }
        return dict
    }
}