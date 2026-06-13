import SwiftUI

// MARK: - UsagePanelView

/// The main content of the Popover, showing usage cards, errors and action buttons.
struct UsagePanelView: View {
    @ObservedObject var appStateProxy: AppStateProxy
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Error summary bar (at the top per PRD)
            if !appStateProxy.errorSummaries.isEmpty {
                ErrorBarView(
                    errors: appStateProxy.errorSummaries,
                    refreshIntervalMinutes: appStateProxy.globalSettings.refreshIntervalMinutes
                )
            }

            if appStateProxy.slotViewDataList.isEmpty && appStateProxy.instances.isEmpty {
                // Empty state — no instances configured at all
                EmptyStateView(openSettings: openSettings)
                    .padding(.vertical, 12)
            } else if appStateProxy.slotViewDataList.isEmpty && !appStateProxy.instances.isEmpty {
                // All instances failed or are disabled — show a compact prompt instead of dead white space
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("Unable to load usage data")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("All instances failed to refresh. Tap Refresh to retry.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 240)
                    Spacer()
                }
                .padding(.vertical, 12)
            } else {
                // Scrollable card list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appStateProxy.slotViewDataList) { slot in
                            UsageCardView(
                                slot: slot,
                                lastRefreshAt: appStateProxy.lastRefreshAt
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
}

// MARK: - PlaceholderContentView

struct PlaceholderContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Usage Panel")
                .font(.headline)
            Text("(Pending development)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 280, height: 200)
    }
}

// MARK: - ErrorBarView

struct ErrorBarView: View {
    let errors: [ErrorSummary]
    let refreshIntervalMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(errors) { error in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                        .padding(.top, 1)

                    Text("\(error.displayName): \(formattedMessage(for: error.errorType))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func formattedMessage(for errorType: ErrorType) -> String {
        switch errorType {
        case .networkTimeout, .networkUnreachable:
            return "Network error, retrying in \(refreshIntervalMinutes) min"
        case .authFailed:
            return "API Key invalid, check settings"
        case .apiError(let code):
            return "API error (code: \(code))"
        }
    }
}


