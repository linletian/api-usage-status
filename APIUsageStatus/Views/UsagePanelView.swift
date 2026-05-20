import SwiftUI

// MARK: - UsagePanelView

struct UsagePanelView: View {
    @ObservedObject var appStateProxy: AppStateProxy
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if appStateProxy.slotViewDataList.isEmpty && appStateProxy.instances.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Spacer()
                    Text("No services configured")
                        .font(.headline)
                    Text("Click the menu bar icon to add your first service")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Add First Service") {
                        openSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(20)
                .frame(width: 280, height: 200)
            } else {
                // Show slot data list
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appStateProxy.slotViewDataList) { slot in
                            SlotCardView(slot: slot)
                        }
                    }
                    .padding()
                }

                // Error summary bar
                if !appStateProxy.errorSummaries.isEmpty {
                    ErrorBarView(errors: appStateProxy.errorSummaries)
                }

                // Action buttons
                HStack {
                    Button(appStateProxy.isRefreshing ? "Refreshing..." : "Refresh") {
                        Task {
                            await appStateProxy.triggerManualRefresh()
                        }
                    }
                    .disabled(appStateProxy.isRefreshing)

                    Spacer()

                    Button("Settings") {
                        openSettings()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 300, height: 400)
    }
}

// MARK: - SlotCardView

struct SlotCardView: View {
    let slot: SlotViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(slot.shortName.isEmpty ? "??" : slot.shortName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))

                Spacer()

                ColorStateBadge(state: slot.colorState)
            }

            switch slot.instanceType {
            case .quota(let percent, let usageValue, let limitValue, let nextMinutes, let cycleDays):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(percent / 100.0, 1.0))
                        .progressViewStyle(.linear)

                    HStack {
                        Text("\(usageValue) / \(limitValue)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(percent))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                        Text("~\(nextMinutes)m")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

            case .balance(let amount, let isAvailable, let currency):
                if isAvailable {
                    HStack {
                        Text("\(currency?.currencySymbol ?? "¥")\(amount)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                        Spacer()
                        if let todayUsage = slot.todayUsage {
                            Text("~\(currency?.currencySymbol ?? "¥")\(todayUsage) today")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("N/A - Unavailable")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - ColorStateBadge

struct ColorStateBadge: View {
    let state: ColorState

    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateText)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private var stateColor: Color {
        switch state {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .disabled, .unavailable, .loading, .error: return .gray
        }
    }

    private var stateText: String {
        switch state {
        case .normal: return "OK"
        case .warning: return "WARN"
        case .critical: return "CRIT"
        case .disabled: return "OFF"
        case .unavailable: return "N/A"
        case .loading: return "..."
        case .error: return "ERR"
        }
    }
}

// MARK: - ErrorBarView

struct ErrorBarView: View {
    let errors: [ErrorSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(errors) { error in
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 10))
                    Text("\(error.displayName): \(error.errorMessage)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.1))
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