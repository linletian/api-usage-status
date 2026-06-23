import SwiftUI

// MARK: - UsageCardView

/// A single instance usage card shown inside the Popover.
struct UsageCardView: View {
    let slot: SlotViewData
    let lastRefreshAt: Date?

    /// Error summary for this slot's instance from the most recent
    /// failed cycle (per UUID). Used by the footer to display the
    /// error message alongside the "Cached X ago" copy.
    var staleError: ErrorSummary? = nil

    /// True when the quota cycle window has passed (e.g., a 5h window
    /// that ended). Rendered as a "Window expired" hint.
    var windowExpired: Bool = false

    /// True when a refresh cycle currently targeting this instance is
    /// in flight (either via global Refresh that includes this instance,
    /// or a per-instance click). The status dot swaps to a spinner in
    /// this state.
    var isRefreshing: Bool = false

    /// Tapping the status dot refreshes just this instance. Wired by
    /// the panel via `appStateProxy.triggerInstanceRefresh`. Nil in
    /// read-only previews / tests.
    var onRefreshTapped: (() -> Void)? = nil

    /// Stale/cached data flag — read from `slot.isStale` (the single
    /// source of truth for staleness per `docs/ARCHITECTURE.md §7.5`).
    /// The menu bar reads the same field to decide whether to layer 80%
    /// alpha on top of the threshold color.
    private var isStale: Bool {
        slot.isStale
    }

    private var displayTitle: String {
        slot.displayName.isEmpty ? slot.shortName : slot.displayName
    }

    private var providerURL: URL? {
        // Match on the enum so `slot.provider`'s exact rawValue string is what
        // we dispatch on — the previous `slot.provider.lowercased()` form
        // silently dropped GitHub Copilot because its rawValue is the
        // camelCase "githubCopilot" and lowercasing the input produces
        // "githubcopilot".
        guard let provider = Provider(rawValue: slot.provider) else { return nil }
        switch provider {
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/usage")
        case .minimax:
            return URL(string: "https://platform.minimaxi.com/user-center/payment/token-plan")
        case .githubCopilot:
            return URL(string: "https://github.com/settings/billing/ai_usage")
        case .opencode:
            // Read the cache only — log scanning happens off-thread at app
            // launch via `OpenCodeWorkspaceResolver.prewarm()`. On a cold
            // cache, fall through to the public Go landing page.
            if let id = OpenCodeWorkspaceResolver.cachedWorkspaceID() {
                return URL(string: "https://opencode.ai/workspace/\(id)/go")
            }
            return URL(string: "https://opencode.ai/zh/go")
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
                ColorStateBadge(
                    state: slot.colorState,
                    isRefreshing: isRefreshing,
                    onRefreshTapped: onRefreshTapped
                )
            }

            // Content
            if slot.metricSnapshots.count > 1 {
                multiMetricContent
            } else {
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
            }

            // Footer: See details button + Last refresh time / stale info.
            // `lastTextBaseline` anchors the See details button to the bottom
            // row of `footerStatusView` (1–3 rows depending on stale / window-expired
            // state), keeping it visually pinned to the bottom-left of the card.
            HStack(alignment: .lastTextBaseline) {
                if let url = providerURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text("See details")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.textSecondary)
                }

                Spacer()

                footerStatusView
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isStale ? Color.cardBgDim : Color.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.progressTrackBg, lineWidth: 0.5)
        )
    }

    /// Right-aligned status text in the footer. Three layouts:
    ///   1. Stale (cached) → "⚠ {error}" + "Cached X ago"
    ///   2. Fresh + window expired → "Window expired"
    ///   3. Fresh + window active → "Updated HH:MM"
    @ViewBuilder
    private var footerStatusView: some View {
        if isStale {
            VStack(alignment: .trailing, spacing: 2) {
                if let message = staleError?.errorMessage {
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(message)
                    }
                    .font(.system(size: 9))
                    .foregroundColor(Color.warningYellow)
                }
                if let cachedAt = slot.lastFetchedAt {
                    Text("Cached \(cachedAt.timeSinceNow) ago")
                        .font(.system(size: 9))
                        .foregroundColor(Color.textSecondary)
                }
            }
        } else if windowExpired {
            Text("Window expired")
                .font(.system(size: 9))
                .foregroundColor(Color.textSecondary)
        } else if let lastRefresh = lastRefreshAt {
            Text(formattedTime(lastRefresh))
                .font(.system(size: 9))
                .foregroundColor(.textSecondary)
        }
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
            quotaSummaryRow(usageValue: usageValue, limitValue: limitValue, percent: percent, overageUSD: slot.metricSnapshots.first?.overageUSD ?? 0)
            quotaProgressBar(percent: percent, height: 4)

            // Countdown row: "Xh Ym remaining" (until the quota window
            // resets) on the right. The "Next refresh" countdown is a
            // global value shared by all cards, so it's displayed once
            // at the bottom of the panel next to the Refresh button.
            // `TimelineView` re-renders every minute so the countdown
            // ticks down between refreshes; the timeline is cancelled
            // automatically when this view is unmounted (popover
            // closed), so no CPU is spent while the popup is hidden.
            HStack {
                Spacer()
                if let endTime = firstCycleEndTime {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let remaining = formatRemainingTime(endTime: endTime, now: context.date) {
                            Text(remaining)
                                .font(.system(size: 9))
                                .foregroundColor(.textSecondary)
                        }
                    }
                } else if let remaining = formatRemainingTime(cycleRemainingSeconds) {
                    // Fallback for snapshots without a recorded end time
                    // (legacy or balance-style): render the static value
                    // captured at refresh time.
                    Text(remaining)
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
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
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("∞ unlimited")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.textSecondary)
                }
                FlowingGlowBar()
            } else {
                HStack(spacing: 4) {
                    Text("Weekly · \(String(format: "%.1f", weekly.remaining))% left")
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("\(Int(weekly.percent))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(weekly.percent >= 95 ? .dangerRed : (weekly.percent >= 80 ? .warningYellow : .textSecondary))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.progressTrackBg)
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
    /// Kept as a static-at-refresh overload for callers that only have
    /// the relative seconds (e.g. legacy fixtures, balance paths).
    private func formatRemainingTime(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        return Self.formatRemainingTime(seconds: seconds)
    }

    /// Live "Xh Ym remaining" formatter driven by `TimelineView`. The
    /// view passes `context.date` so the countdown ticks down between
    /// refreshes. Returns nil when `endTime` is in the past or not set.
    private func formatRemainingTime(endTime: Date?, now: Date) -> String? {
        guard let endTime else { return nil }
        let seconds = max(0, Int(endTime.timeIntervalSince(now)))
        return Self.formatRemainingTime(seconds: seconds)
    }

    /// Pure formatter: seconds → "Xd" / "Xh Ym" / "Xm" + " remaining".
    /// Returns nil for 0 / negative. Sub-minute values are rounded up
    /// to "1m" so the countdown doesn't flicker between "0m" and "1m"
    /// near window close. Internal (not `private`) so
    /// `UsageCardViewTests` can exercise the three branches directly
    /// instead of mirroring the logic.
    static func formatRemainingTime(seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        if seconds >= 86_400 {
            let days = seconds / 86_400
            return "\(days)d remaining"
        } else if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return "\(hours)h \(minutes)m remaining"
        } else {
            let minutes = max(1, seconds / 60)
            return "\(minutes)m remaining"
        }
    }

    @ViewBuilder
    private func quotaSummaryRow(usageValue: String, limitValue: String, percent: Double, overageUSD: Double = 0) -> some View {
        HStack(spacing: 4) {
            Text(quotaSummaryText(usageValue: usageValue, limitValue: limitValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.textSecondary)
            Spacer()
            Text(overagePercentText(percent: percent, overageUSD: overageUSD))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(percent >= 95 ? .dangerRed : (percent >= 80 ? .warningYellow : .textPrimary))
        }
    }

    private func overagePercentText(percent: Double, overageUSD: Double) -> String {
        guard percent > 100 else { return "\(Int(percent))%" }
        switch slot.provider {
        case Provider.githubCopilot.rawValue:
            return "100% + \(String(format: "%.1f", percent - 100))%"
        case Provider.opencode.rawValue:
            return "100% + $\(String(format: "%.2f", overageUSD))"
        default:
            return "\(Int(percent))%"
        }
    }

    @ViewBuilder
    private func quotaProgressBar(percent: Double, height: CGFloat) -> some View {
        if percent > 100 {
            overageProgressBar(percent: percent, height: height)
        } else {
            normalProgressBar(percent: percent, height: height)
        }
    }

    @ViewBuilder
    private func normalProgressBar(percent: Double, height: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.progressTrackBg)
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

    @ViewBuilder
    private func overageProgressBar(percent: Double, height: CGFloat) -> some View {
        let quotaFraction = 100.0 / percent
        let overageFraction = (percent - 100.0) / percent
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.progressTrackBg)
                    .frame(height: height)
                // Segment 1: solid red for the 100% quota portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.dangerRed)
                    .frame(width: geo.size.width * CGFloat(quotaFraction), height: height)
                // Segment 2: zebra-striped for the overage portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.dangerRed.opacity(0.25))
                    .frame(width: geo.size.width * CGFloat(overageFraction), height: height)
                    .overlay(
                        Canvas { context, size in
                            let stripeSpacing: CGFloat = 4
                            var x: CGFloat = -size.height
                            while x < size.width {
                                var path = Path()
                                path.move(to: CGPoint(x: x, y: size.height))
                                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                                context.stroke(path, with: .color(.dangerRed), lineWidth: 1.5)
                                x += stripeSpacing
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    )
                    .offset(x: geo.size.width * CGFloat(quotaFraction))
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
                        .foregroundColor(.textSecondary)
                }

                // Daily averages
                if let averages = slot.dailyAverages, !averages.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily avg")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.textSecondary)
                        ForEach(
                            Array(averages.keys.sorted { $0.rawValue < $1.rawValue }),
                            id: \.self
                        ) { period in
                            if let avg = averages[period] {
                                HStack {
                                    Text(period.displayName)
                                        .font(.system(size: 9))
                                        .foregroundColor(.textSecondary)
                                    Spacer()
                                    Text(formattedDecimal(avg, currency: currency))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.textPrimary)
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
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text((currency?.currencySymbol ?? "¥") + amount)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.textSecondary)
                    }
                    if !grantedBalance.isEmpty && grantedBalance != "0" && grantedBalance != "0.00" {
                        HStack {
                            Text("Granted")
                                .font(.system(size: 9))
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Text((currency?.currencySymbol ?? "¥") + grantedBalance)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.textSecondary)
                        }
                    }
                    HStack {
                        Text("Total")
                            .font(.system(size: 9))
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Text((currency?.currencySymbol ?? "¥") + totalBalance)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.textSecondary)
                    }
                }
                .padding(.top, 2)
            }
        } else {
            HStack {
                Text("N/A - Unavailable")
                    .font(.system(size: 11))
                    .foregroundColor(.textSecondary)
                Spacer()
            }
        }
    }

    // MARK: - Multi-Metric Content

    @ViewBuilder
    private var multiMetricContent: some View {
        let visibleSnapshots = slot.metricSnapshots.filter { $0.displayInMenuBar }
        VStack(alignment: .leading, spacing: 4) {
            if visibleSnapshots.isEmpty {
                // All metrics hidden — show placeholder matching single-metric fallback
                quotaFallbackContent
            } else if slot.provider == Provider.minimax.rawValue {
                groupedMetricContent(snapshots: visibleSnapshots)
            } else {
                flatMetricContent(snapshots: visibleSnapshots)
            }

            // Live "Xh Ym remaining" footer for the multi-metric layout
            // (used by DeepSeek / OpenCode / Copilot). Mirrors the
            // single-metric countdown: prefer `cycleEndTime` and tick it
            // down with `TimelineView`; fall back to the static-at-refresh
            // value when no end time is recorded.
            HStack {
                Spacer()
                if let endTime = firstCycleEndTime {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let remaining = formatRemainingTime(endTime: endTime, now: context.date) {
                            Text(remaining)
                                .font(.system(size: 9))
                                .foregroundColor(.textSecondary)
                        }
                    }
                } else if let remaining = formatRemainingTime(firstCycleRemaining) {
                    Text(remaining)
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }

    private var quotaFallbackContent: some View {
        let first = slot.metricSnapshots.first
        return quotaContent(
            percent: first?.percent ?? 0,
            usageValue: first?.displayUsage ?? "",
            limitValue: first?.displayLimit ?? "",
            cycleRemainingSeconds: first?.cycleRemainingSeconds
        )
    }

    @ViewBuilder
    private func groupedMetricContent(snapshots: [MetricSnapshot]) -> some View {
        let groups = Dictionary(grouping: snapshots, by: { $0.group ?? "" })
        let sortedGroupKeys = groups.keys.sorted()

        ForEach(sortedGroupKeys, id: \.self) { groupKey in
            if let snapshots = groups[groupKey] {
                VStack(alignment: .leading, spacing: 2) {
                    if !groupKey.isEmpty {
                        Text(groupKey.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.textSecondary)
                    }

                    let sorted = snapshots.sorted { windowSortOrder($0.window) < windowSortOrder($1.window) }
                    ForEach(sorted, id: \.key) { snapshot in
                        metricRow(snapshot: snapshot)
                    }
                }

                if groupKey != sortedGroupKeys.last {
                    Divider().padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func flatMetricContent(snapshots: [MetricSnapshot]) -> some View {
        let sorted = snapshots.sorted { windowSortOrder($0.window) < windowSortOrder($1.window) }
        ForEach(sorted, id: \.key) { snapshot in
            metricRow(snapshot: snapshot)
        }
    }

    @ViewBuilder
    private func metricRow(snapshot: MetricSnapshot) -> some View {
        if snapshot.isUnlimited {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(metricLabel(for: snapshot))
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                    Spacer()
                    Text("∞ unlimited")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.textSecondary)
                }
                FlowingGlowBar()
                    .frame(height: 3)
            }
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(metricLabel(for: snapshot))
                        .font(.system(size: 9))
                        .foregroundColor(.textSecondary)
                    if !snapshot.displayLimit.isEmpty {
                        Text("\(snapshot.displayUsage) / \(snapshot.displayLimit)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.textSecondary)
                    }
                    Spacer()
                    Text(overagePercentText(percent: snapshot.percent, overageUSD: snapshot.overageUSD))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(percentTextColor(for: snapshot.percent))
                }
                quotaProgressBar(percent: snapshot.percent, height: 3)
            }
        }
    }

    private func metricLabel(for snapshot: MetricSnapshot) -> String {
        guard let window = snapshot.window else { return snapshot.key }
        switch window {
        case "5h": return "5h"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        default: return window.capitalized
        }
    }

    private func percentTextColor(for percent: Double) -> Color {
        if percent >= 95 { return .dangerRed }
        if percent >= 80 { return .warningYellow }
        return .textPrimary
    }

    private func windowSortOrder(_ window: String?) -> Int {
        switch window {
        case "5h": return 0
        case "weekly": return 1
        case "monthly": return 2
        default: return 3
        }
    }

    private var firstCycleRemaining: Int? {
        slot.metricSnapshots.first(where: { $0.cycleRemainingSeconds != nil })?.cycleRemainingSeconds
    }

    /// First snapshot that carries a `cycleEndTime` — the absolute window
    /// end time the view feeds to `TimelineView` for the live countdown.
    /// Falls back to `nil` for legacy snapshots where the parser didn't
    /// record an end time; in that case the view renders the static
    /// `cycleRemainingSeconds` value instead.
    private var firstCycleEndTime: Date? {
        slot.metricSnapshots.first(where: { $0.cycleEndTime != nil })?.cycleEndTime
    }

    // MARK: - Helpers

    private func progressColor(for percent: Double) -> Color {
        if percent >= 95 {
            return .dangerRed
        } else if percent >= 80 {
            return .warningYellow
        }
        return .trackingOn
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
    var isRefreshing: Bool = false
    var onRefreshTapped: (() -> Void)? = nil

    var body: some View {
        let indicator = HStack(spacing: 2) {
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
            }
            Text(stateText)
                .font(.system(size: 9))
                .foregroundColor(.textSecondary)
        }

        if let tap = onRefreshTapped {
            Button(action: tap) {
                indicator
            }
            .buttonStyle(.plain)
            .help(isRefreshing ? "Refreshing…" : "Refresh this instance")
            // When a refresh is in flight, the dot gesture is intentionally
            // inert — `RefreshService.triggerInstanceRefresh` will no-op
            // anyway, but disabling the visual hint makes the state
            // unambiguous to the user.
            .disabled(isRefreshing)
        } else {
            indicator
        }
    }

    private var stateColor: Color {
        switch state {
        case .normal:       return .trackingOn
        case .warning:      return .warningYellow
        case .critical:     return .dangerRed
        case .disabled, .unavailable, .loading, .error:
            return .textTertiary
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


