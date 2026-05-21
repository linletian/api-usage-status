import SwiftUI

// MARK: - UsageCardView

/// A single instance usage card shown inside the Popover.
struct UsageCardView: View {
    let slot: SlotViewData
    let lastRefreshAt: Date?

    private var displayTitle: String {
        slot.displayName.isEmpty ? slot.shortName : slot.displayName
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
            case .quota(let percent, let usageValue, let limitValue, let nextMinutes, let cycleDays):
                quotaContent(
                    percent: percent,
                    usageValue: usageValue,
                    limitValue: limitValue,
                    nextMinutes: nextMinutes,
                    cycleDays: cycleDays
                )
            case .balance(let amount, let isAvailable, let currency):
                balanceContent(
                    amount: amount,
                    isAvailable: isAvailable,
                    currency: currency
                )
            }

            // Last refresh time
            if let lastRefresh = lastRefreshAt {
                HStack {
                    Spacer()
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

    @ViewBuilder
    private func quotaContent(
        percent: Double,
        usageValue: String,
        limitValue: String,
        nextMinutes: Int,
        cycleDays: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(progressColor(for: percent))
                        .frame(
                            width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent) / 100.0)),
                            height: 4
                        )
                }
            }
            .frame(height: 4)

            HStack(spacing: 4) {
                Text("\(usageValue) / \(limitValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(percent >= 95 ? .red : (percent >= 80 ? .orange : .primary))
            }

            HStack {
                Text("Next refresh: ~\(nextMinutes)m")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                if let days = cycleDays, days > 0 {
                    Text("\(days)d remaining")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Balance Content

    @ViewBuilder
    private func balanceContent(
        amount: String,
        isAvailable: Bool,
        currency: String?
    ) -> some View {
        if isAvailable {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(currency?.currencySymbol ?? "¥")
                        .font(.system(size: 12, weight: .medium))
                    Text(amount)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                    Spacer()
                }

                if let today = slot.todayUsage, !today.isEmpty {
                    Text("约 \(currency?.currencySymbol ?? "¥")\(today) today")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

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


