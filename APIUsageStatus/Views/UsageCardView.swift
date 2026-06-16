import SwiftUI

// MARK: - UsageCardView

/// A single instance usage card shown inside the Popover.
struct UsageCardView: View {
    let slot: SlotViewData
    let lastRefreshAt: Date?

    private var displayTitle: String {
        slot.displayName.isEmpty ? slot.shortName : slot.displayName
    }

    private var providerURL: URL? {
        switch slot.provider.lowercased() {
        case "deepseek":
            return URL(string: "https://platform.deepseek.com/usage")
        case "minimax":
            return URL(string: "https://platform.minimaxi.com/user-center/payment/token-plan")
        case "githubcopilot":
            return URL(string: "https://github.com/settings/billing/ai_usage")
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text(displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                ColorStateBadge(state: slot.colorState)
            }

            // Content
            switch slot.instanceType {
            case .quota(let percent, let usageValue, let limitValue, let cycleRemainingSeconds):
                quotaContent(
                    percent: percent,
                    usageValue: usageValue,
                    limitValue: limitValue,
                    cycleRemainingSeconds: cycleRemainingSeconds
                )
            case .balance(let amount, let totalBalance, let grantedBalance, let isAvailable, let currency):
                balanceContent(
                    amount: amount,
                    totalBalance: totalBalance,
                    grantedBalance: grantedBalance,
                    isAvailable: isAvailable,
                    currency: currency
                )
            }

            // Footer: See details button + Last refresh time
            HStack {
                if let url = providerURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("See details")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                }

                Spacer()

                if let lastRefresh = lastRefreshAt {
                    Text(formattedTime(lastRefresh))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Quota Content

    /// Per-window label, e.g. "5h" / "Weekly" / "Monthly". Single-window
    /// providers (Copilot, MiniMax) hardcode their label; OpenCode picks
    /// from three window names based on `slot.dimension`.
    private var quotaWindowLabel: String {
        switch slot.provider {
        case Provider.githubCopilot.rawValue: return "Monthly"
        case Provider.minimax.rawValue: return "5h"
        case Provider.opencode.rawValue:
            switch slot.dimension {
            case "5h":     return "5h"
            case "weekly": return "Weekly"
            case "monthly": return "Monthly"
            default:       return ""
            }
        default: return ""
        }
    }

    private var quotaUnitLabel: String {
        switch slot.provider {
        case Provider.githubCopilot.rawValue: return "credits"
        case Provider.opencode.rawValue: return "USD"
        default: return ""
        }
    }

    @ViewBuilder
    private func quotaContent(
        percent: Double,
        usageValue: String,
        limitValue: String,
        cycleRemainingSeconds: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // All quota-type providers use text-above-bar to match the
            // Weekly section layout. Balance-type instances have their
            // own layout and don't go through this path.
            quotaSummaryRow(usageValue: usageValue, limitValue: limitValue, percent: percent)
            quotaProgressBar(percent: percent, height: 4)

            // Countdown row: "Xh Ym remaining" (until the quota window
            // resets) on the right. The "Next refresh" countdown is a
            // global value shared by all cards, so it's displayed once
            // at the bottom of the panel next to the Refresh button.
            HStack {
                Spacer()
                if let remaining = formatRemainingTime(cycleRemainingSeconds) {
                    Text(remaining)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            // Weekly section starts on its own line below the countdown row.
            if let weekly = slot.weekly {
                weeklySection(weekly: weekly)
            }
        }
    }

    @ViewBuilder
    private func weeklySection(weekly: WeeklyQuota) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if weekly.isUnlimited {
                HStack(spacing: 4) {
                    Text("Weekly")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("∞ unlimited")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                FlowingGlowBar()
            } else {
                HStack(spacing: 4) {
                    Text("Weekly · \(String(format: "%.1f", weekly.remaining))% left")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(weekly.percent))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(weekly.percent >= 95 ? .red : (weekly.percent >= 80 ? .orange : .secondary))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(progressColor(for: weekly.percent))
                            .frame(
                                width: max(0, min(geo.size.width, geo.size.width * CGFloat(weekly.percent) / 100.0)),
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Quota subviews

    private func quotaSummaryText(usageValue: String, limitValue: String) -> String {
        // For percent-only providers (no denominator), the left side just
        // shows the window label — the percent is already on the right,
        // so duplicating it on the left would be redundant.
        if limitValue.isEmpty {
            return quotaWindowLabel
        }
        var parts: [String] = []
        if !quotaWindowLabel.isEmpty { parts.append(quotaWindowLabel) }
        parts.append("\(usageValue) / \(limitValue)")
        if !quotaUnitLabel.isEmpty { parts.append(quotaUnitLabel) }
        return parts.joined(separator: " · ")
    }

    /// Format cycle remaining seconds into a human-readable string.
    /// Returns nil if the value is 0 or negative (no point showing).
    private func formatRemainingTime(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 86_400 {
            let days = seconds / 86_400
            return "\(days)d remaining"
        } else if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return "\(hours)h \(minutes)m remaining"
        } else {
            // Sub-minute values are rounded up to "1m" so the countdown
            // doesn't flicker between "0m" and "1m" near window close.
            let minutes = max(1, seconds / 60)
            return "\(minutes)m remaining"
        }
    }

    @ViewBuilder
    private func quotaSummaryRow(usageValue: String, limitValue: String, percent: Double) -> some View {
        HStack(spacing: 4) {
            Text(quotaSummaryText(usageValue: usageValue, limitValue: limitValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(Int(percent))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(percent >= 95 ? .red : (percent >= 80 ? .orange : .primary))
        }
    }

    @ViewBuilder
    private func quotaProgressBar(percent: Double, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: height)
                RoundedRectangle(cornerRadius: 2)
                    .fill(progressColor(for: percent))
                    .frame(
                        width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent) / 100.0)),
                        height: height
                    )
            }
        }
        .frame(height: height)
    }

    // MARK: - Balance Content

    @ViewBuilder
    private func balanceContent(
        amount: String,
        totalBalance: String,
        grantedBalance: String,
        isAvailable: Bool,
        currency: String?
    ) -> some View {
        if isAvailable {
            VStack(alignment: .leading, spacing: 4) {
                // Primary balance (topped_up_balance)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(currency?.currencySymbol ?? "¥")
                        .font(.system(size: 12, weight: .medium))
                    Text(amount)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                    Spacer()
                }

                // Today usage
                if let today = slot.todayUsage, !today.isEmpty {
                    Text("≈ \(currency?.currencySymbol ?? "¥")\(today) today")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // Daily averages
                if let averages = slot.dailyAverages, !averages.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily avg")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        ForEach(
                            Array(averages.keys.sorted { $0.rawValue < $1.rawValue }),
                            id: \.self
                        ) { period in
                            if let avg = averages[period] {
                                HStack {
                                    Text(period.displayName)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(formattedDecimal(avg, currency: currency))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                }

                // Balance breakdown: topped_up vs total
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text("Topped Up")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text((currency?.currencySymbol ?? "¥") + amount)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    if !grantedBalance.isEmpty && grantedBalance != "0" && grantedBalance != "0.00" {
                        HStack {
                            Text("Granted")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text((currency?.currencySymbol ?? "¥") + grantedBalance)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Total")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text((currency?.currencySymbol ?? "¥") + totalBalance)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        } else {
            HStack {
                Text("N/A - Unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func progressColor(for percent: Double) -> Color {
        if percent >= 95 {
            return .red
        } else if percent >= 80 {
            return .orange
        }
        return .green
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Updated \(formatter.string(from: date))"
    }

    private func formattedDecimal(_ value: Decimal, currency: String?) -> String {
        let symbol = currency?.currencySymbol ?? "¥"
        return symbol + value.formatted(decimalPlaces: 2)
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
        case .normal:       return .green
        case .warning:      return .yellow
        case .critical:     return .red
        case .disabled, .unavailable, .loading, .error:
            return .gray
        }
    }

    private var stateText: String {
        switch state {
        case .normal:       return "OK"
        case .warning:      return "WARN"
        case .critical:     return "CRIT"
        case .disabled:     return "OFF"
        case .unavailable:  return "N/A"
        case .loading:      return "..."
        case .error:        return "ERR"
        }
    }
}

// MARK: - FlowingGlowBar

/// A thin progress bar that conveys "no limit" via a continuously flowing
/// luminous band travelling from left to right. Used in place of a normal
/// progress bar when the underlying quota is not enforced (e.g. MiniMax
/// weekly limit on plans that do not include a weekly cap).
///
/// Animation is driven by `TimelineView`, so the schedule is part of the
/// view's definition rather than an implicit animation state machine. When
/// the view leaves the hierarchy, SwiftUI tears down the timeline and stops
/// driving redraws — no manual start/stop is needed.
struct FlowingGlowBar: View {
    private let barHeight: CGFloat = 3
    private let shimmerWidthFraction: CGFloat = 0.45
    private let duration: Double = 2.4

    var body: some View {
        TimelineView(.animation) { context in
            let phase = CGFloat(
                context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration
            )
            ShimmerBar(
                phase: phase,
                barHeight: barHeight,
                shimmerWidthFraction: shimmerWidthFraction
            )
        }
        .frame(height: barHeight)
    }
}

// MARK: - ShimmerBar

/// Renders the glow strip at a fixed phase. Extracted from `FlowingGlowBar`
/// so snapshot tests can render a deterministic frame.
struct ShimmerBar: View {
    let phase: CGFloat
    let barHeight: CGFloat
    let shimmerWidthFraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width
            let shimmerWidth = barWidth * shimmerWidthFraction
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyan.opacity(0.18),
                                Color.blue.opacity(0.28),
                                Color.cyan.opacity(0.18)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: barHeight)
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: Color.cyan.opacity(0.95), location: 0.45),
                                .init(color: Color.white, location: 0.5),
                                .init(color: Color.cyan.opacity(0.95), location: 0.55),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: shimmerWidth, height: barHeight)
                    .shadow(color: Color.cyan.opacity(0.7), radius: 4, x: 0, y: 0)
                    .offset(x: (barWidth + shimmerWidth) * phase - shimmerWidth)
                    .blendMode(.plusLighter)
            }
            .clipped()
        }
    }
}


