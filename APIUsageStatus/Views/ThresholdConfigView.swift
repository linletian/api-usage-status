import SwiftUI

// MARK: - ThresholdConfigView

struct ThresholdConfigView: View {
    @Binding var thresholds: Thresholds

    var body: some View {
        Group {
            switch thresholds {
            case .quota:
                quotaSection
            case .balance:
                balanceSection
            }
        }
    }

    // MARK: - Quota Thresholds

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Warning")
                Spacer()
                Text("\(quotaWarning)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.warningYellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.warningYellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            GradientSlider(value: quotaWarningBinding, range: 0 ... 100)

            HStack {
                Text("Critical")
                Spacer()
                Text("\(quotaCritical)%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Color.criticalRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.criticalRed.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            GradientSlider(value: quotaCriticalBinding, range: 0 ... 100)

            if quotaWarning >= quotaCritical {
                Text("Warning must be less than critical")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var quotaWarning: Int {
        if case .quota(let w, _) = thresholds { return w }
        return 80
    }

    private var quotaCritical: Int {
        if case .quota(_, let c) = thresholds { return c }
        return 95
    }

    private var quotaWarningBinding: Binding<Double> {
        Binding(
            get: { Double(quotaWarning) },
            set: { newValue in
                if case .quota(_, let c) = thresholds {
                    thresholds = .quota(warningPercent: Int(newValue), criticalPercent: c)
                }
            }
        )
    }

    private var quotaCriticalBinding: Binding<Double> {
        Binding(
            get: { Double(quotaCritical) },
            set: { newValue in
                if case .quota(let w, _) = thresholds {
                    thresholds = .quota(warningPercent: w, criticalPercent: Int(newValue))
                }
            }
        )
    }

    // MARK: - Balance Thresholds

    @ViewBuilder
    private var balanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Warning threshold")
                Spacer()
                TextField("e.g. 10.00", text: balanceWarningBinding)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("Critical threshold")
                Spacer()
                TextField("e.g. 2.00", text: balanceCriticalBinding)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            if let warning = balanceWarningDecimal,
               let critical = balanceCriticalDecimal,
               warning <= critical
            {
                Text("Warning must be greater than critical")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Text("Average daily periods")
                .font(.subheadline)
                .padding(.top, 4)

            ForEach(AvgDailyPeriod.allCases, id: \.self) { period in
                Toggle(period.displayName, isOn: periodBinding(for: period))
            }

            HStack {
                Text("History retention (days, 0 = forever)")
                Spacer()
                TextField("0", text: historyRetentionBinding)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var balanceWarningDecimal: Decimal? {
        if case .balance(let w, _, _, _) = thresholds {
            return w
        }
        return nil
    }

    private var balanceCriticalDecimal: Decimal? {
        if case .balance(_, let c, _, _) = thresholds {
            return c
        }
        return nil
    }

    private var balanceWarningBinding: Binding<String> {
        Binding(
            get: {
                if case .balance(let w, _, _, _) = thresholds {
                    return w.formatted(decimalPlaces: 2)
                }
                return "10.00"
            },
            set: { newValue in
                if let decimal = Decimal(string: newValue),
                   case .balance(_, let c, let p, let h) = thresholds
                {
                    thresholds = .balance(warning: decimal, critical: c, avgDailyPeriods: p, historyRetentionDays: h)
                }
            }
        )
    }

    private var balanceCriticalBinding: Binding<String> {
        Binding(
            get: {
                if case .balance(_, let c, _, _) = thresholds {
                    return c.formatted(decimalPlaces: 2)
                }
                return "2.00"
            },
            set: { newValue in
                if let decimal = Decimal(string: newValue),
                   case .balance(let w, _, let p, let h) = thresholds
                {
                    thresholds = .balance(warning: w, critical: decimal, avgDailyPeriods: p, historyRetentionDays: h)
                }
            }
        )
    }

    private func periodBinding(for period: AvgDailyPeriod) -> Binding<Bool> {
        Binding(
            get: {
                if case .balance(_, _, let periods, _) = thresholds {
                    return periods.contains(period)
                }
                return false
            },
            set: { isOn in
                if case .balance(let w, let c, var periods, let h) = thresholds {
                    if isOn {
                        if !periods.contains(period) {
                            periods.append(period)
                        }
                    } else {
                        periods.removeAll { $0 == period }
                    }
                    thresholds = .balance(warning: w, critical: c, avgDailyPeriods: periods, historyRetentionDays: h)
                }
            }
        )
    }

    private var historyRetentionBinding: Binding<String> {
        Binding(
            get: {
                if case .balance(_, _, _, let days) = thresholds {
                    return "\(days)"
                }
                return "0"
            },
            set: { newValue in
                if let days = Int(newValue),
                   case .balance(let w, let c, let p, _) = thresholds
                {
                    thresholds = .balance(warning: w, critical: c, avgDailyPeriods: p, historyRetentionDays: days)
                }
            }
        )
    }
}

// MARK: - GradientSlider

/// A slider with a gradient-filled track that transitions from
/// `warningYellow` (left) to `criticalRed` (right), giving a visual
/// cue that higher percentages are more severe.
struct GradientSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        Slider(value: $value, in: range)
            .tint(
                LinearGradient(
                    colors: [Color.warningYellow, Color.criticalRed],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}
