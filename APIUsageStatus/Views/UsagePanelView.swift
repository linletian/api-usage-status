import SwiftUI

// MARK: - UsagePanelView

/// The main content of the Popover, showing usage cards, errors and action buttons.
struct UsagePanelView: View {
    @ObservedObject var appStateProxy: AppStateProxy
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if appStateProxy.slotViewDataList.isEmpty && appStateProxy.instances.isEmpty {
                // Empty state — no instances configured at all
                EmptyStateView(openSettings: openSettings)
                    .padding(.vertical, 12)
            } else if appStateProxy.slotViewDataList.isEmpty && !appStateProxy.instances.isEmpty {
                // All instances failed or are disabled AND we have no
                // usable "last successful" cache for today → fully error.
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 28))
                        .foregroundColor(Color.textSecondary.opacity(0.6))
                    Text("Unable to load usage data")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.textPrimary)
                    Text("All instances failed to refresh. Tap Refresh to retry.")
                        .font(.caption)
                        .foregroundColor(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                // Scrollable card list. Staleness is encoded on each slot
                // via `slot.isStale` (per docs/ARCHITECTURE.md §7.5), so
                // each card reads its own stale state directly.
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appStateProxy.slotViewDataList) { slot in
                            UsageCardView(
                                slot: slot,
                                lastRefreshAt: appStateProxy.lastRefreshAt,
                                staleError: errorSummaryByUUID[slot.uuid],
                                windowExpired: isWindowExpired(slot)
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Action buttons
            HStack(spacing: 12) {
                Button {
                    Task {
                        await appStateProxy.triggerManualRefresh()
                    }
                } label: {
                    HStack(spacing: 4) {
                        if appStateProxy.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text(appStateProxy.isRefreshing ? "Refreshing..." : "Refresh")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .disabled(appStateProxy.isRefreshing)
                .buttonStyle(.borderless)

                if !appStateProxy.isRefreshing {
                    // Live countdown until the next automatic refresh.
                    // `TimelineView` ticks every minute so the number
                    // decrements without a fresh API refresh; the
                    // timeline is cancelled automatically when this
                    // view is unmounted (popover closed).
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text("Next refresh: ≈ \(minutesUntilNextRefresh(now: context.date))m")
                            .font(.system(size: 9))
                            .foregroundColor(Color.textSecondary)
                    }
                }

                Spacer()

                Button {
                    openSettings()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.system(size: 10, weight: .medium))
                        Text("Settings")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .ignoresSafeArea(edges: .top)
    }

    /// Minutes until the next automatic refresh cycle, evaluated at
    /// `now` (which `TimelineView` advances by 1 minute per tick). All
    /// cards share the same global refresh interval, so this is computed
    /// once at the panel level rather than per-card. Falls back to the
    /// full interval if no refresh has happened yet.
    private func minutesUntilNextRefresh(now: Date) -> Int {
        let intervalMinutes = appStateProxy.globalSettings.refreshIntervalMinutes
        guard let lastRefresh = appStateProxy.lastRefreshAt else {
            return intervalMinutes
        }
        let elapsed = now.timeIntervalSince(lastRefresh)
        let remaining = TimeInterval(intervalMinutes * 60) - elapsed
        return max(0, Int(remaining / 60))
    }

    /// Index errors by instance UUID so each card can look up its own
    /// `staleError` without scanning the array. Built via
    /// `Dictionary(_:uniquingKeysWith:)` with `last-wins` so a
    /// duplicate UUID (defensive-only — this should not happen in
    /// normal operation) is a silent no-op rather than a fatalError.
    private var errorSummaryByUUID: [String: ErrorSummary] {
        Dictionary(appStateProxy.errorSummaries.map { ($0.id, $0) },
                   uniquingKeysWith: { _, last in last })
    }

    /// True when any snapshot in the slot has an expired quota window
    /// (`cycleRemainingSeconds != nil && cycleRemainingSeconds <= 0`).
    /// `nil` means "the API didn't report a window" — that's not the
    /// same as expired, so we treat it as active.
    private func isWindowExpired(_ slot: SlotViewData) -> Bool {
        slot.metricSnapshots.contains { snapshot in
            guard let remaining = snapshot.cycleRemainingSeconds else { return false }
            return remaining <= 0
        }
    }
}

// MARK: - PlaceholderContentView

struct PlaceholderContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Usage Panel")
                .font(.headline)
            Text("(Pending development)")
                .font(.caption)
                .foregroundColor(Color.textSecondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 280, height: 200)
    }
}


