import AppKit
import Combine

// MARK: - MenuBarIconRenderer

/// Renders the menu-bar icon using SF Pro Regular 8pt in a two-line stacked layout.
/// First line: shortName (centered), second line: balance / percentage (centered).
/// Each enabled instance gets its own slot sized by content width, laid out left
/// to right with a horizontal gap between adjacent slots. Slot count is unbounded —
/// macOS truncates the right side if total width exceeds the available menu bar area.
/// Must be called on the main actor because it uses NSImage.lockFocus().
@MainActor
final class MenuBarIconRenderer {

    // MARK: - Colour constants

    private static let dimColor       = NSColor.menuBarDim      // #D6D0A0  see Color+Theme.swift
    private static let safeColor      = NSColor.menuBarSafe     // #4CAF50  see Color+Theme.swift
    private static let warningColor   = NSColor.menuBarWarning  // #FFC107  see Color+Theme.swift
    private static let criticalColor  = NSColor.menuBarCritical // #F44336  see Color+Theme.swift

    // MARK: - Font constants

    /// Regular-weight SF Pro at 8pt — two lines fit in 22pt slot height.
    private static let font     = NSFont.systemFont(ofSize: 8)

    /// Monospaced variant for percentage digits so slot width stays stable.
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)

    // MARK: - Layout constants

    private static let slotHeight: CGFloat = 22.0

    /// Horizontal gap between adjacent slots.
    private static let betweenSlotGap: CGFloat = 10.0

    /// Alpha applied to the threshold color for stale (refresh-failed) slots.
    /// The text keeps its original threshold color (warning yellow / critical
    /// red / safe) but is dimmed to 80% opacity to signal cached data.
    private static let staleAlpha: CGFloat = 0.8

    /// Animation texts for default state (no instances): cycles through "%" → "%%" → "%%%" → "%" ...
    private static let defaultAnimationTexts = ["%", "%%", "%%%"]

    // MARK: - Breathing state

    private var breathingSlots: Set<String> = []
    private var breathingTimer: Timer?
    private var breathingStartTime: CFTimeInterval = 0
    var currentTimeProvider: () -> CFTimeInterval = { CACurrentMediaTime() }

    /// Breathing animation redraw interval.
    ///
    /// The breathing cycle is 2s (critical) or 4s (warning), so 5 Hz keeps the
    /// blur-radius interpolation visually smooth while cutting per-frame
    /// rendering cost ~12× vs. CVDisplayLink's display-rate firing (which was
    /// driving sustained 80+ fps redraws and burning one core).
    private static let breathingAnimationInterval: TimeInterval = 0.2

    var onNeedsDisplay: (() -> Void)?

    private(set) var defaultAnimationCycleIndex: Int = 0

    private var defaultAnimationTimer: Timer?

    /// 60 s ticker that fires `onNeedsDisplay` whenever a DeepSeek slot is
    /// rendered, so the peak overlay flips at the BJT window boundaries
    /// without waiting for the next refresh cycle (which is typically every
    /// 5+ minutes — too coarse for an hourly boundary hint). Started /
    /// stopped by `MenuBarController` based on whether any DeepSeek slot is
    /// currently visible.
    private var peakTimer: Timer?

    func advanceDefaultAnimationCycle() {
        defaultAnimationCycleIndex = (defaultAnimationCycleIndex + 1) % Self.defaultAnimationTexts.count
        onNeedsDisplay?()
    }

    // MARK: - Public API

    func render(
        slotViewDataList: [SlotViewData],
        colorMode: ColorMode,
        refreshState: RefreshState,
        instancesCount: Int,
        enabledCount: Int,
        isDarkBackground: Bool
    ) -> NSImage {
        // Special states — single centred line
        if instancesCount == 0 {
            return renderDefaultState(colorMode: colorMode, isDarkBackground: isDarkBackground)
        }
        if enabledCount == 0 {
            return renderSpecialCenteredText("NO API")
        }
        if refreshState == .refreshing && slotViewDataList.isEmpty {
            return renderSpecialCenteredText("\u{2022}\u{2022}\u{2022}")
        }

        let expandedSlots = expandToMetricSlots(slotViewDataList)

        if expandedSlots.isEmpty {
            return renderSpecialCenteredText("?")
        }

        // Per-slot content width: each slot is sized by its own content, no equal-width forcing.
        let slotWidths: [CGFloat] = expandedSlots.map { slot in
            if slot.colorState == .unavailable && slot.instanceType.isBalance {
                return textWidth("N/A", font: Self.font)
            }
            return measureSlotContent(slot)
        }

        let totalWidth = slotWidths.reduce(0, +)
            + CGFloat(max(0, slotWidths.count - 1)) * Self.betweenSlotGap

        let size = NSSize(width: totalWidth, height: Self.slotHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        var slotOriginX: CGFloat = 0
        for (index, slot) in expandedSlots.enumerated() {
            let slotWidth = slotWidths[index]

            defer { slotOriginX += slotWidth + Self.betweenSlotGap }

            // Pick the threshold color from `colorForSlot` (which reads
            // `slot.colorState` — the same value whether the slot is stale
            // or fresh). Staleness is then layered on top via alpha only.
            let slotColor = colorForSlot(slot, colorMode: colorMode, isDarkBackground: isDarkBackground)
            let renderColor = slot.isStale ? slotColor.withAlphaComponent(Self.staleAlpha) : slotColor

            // Breathing animation shadow — applied when the threshold is
            // warning or critical. `colorState` is independent of `isStale`,
            // so stale warning/critical slots naturally keep glowing — the
            // alpha reduction above applies to the shadow color too.
            var shadowBlur: CGFloat = 0
            var shadowOp: CGFloat = 0
            if breathingSlots.contains(slot.uuid) {
                let elapsed = currentTimeProvider() - breathingStartTime
                let config: BreathingConfig
                switch slot.colorState {
                case .warning:
                    config = .warning
                case .critical:
                    config = .critical
                default:
                    config = .warning
                }
                let phase = breathingPhase(elapsed: elapsed, config: config)
                shadowBlur = shadowRadius(forPhase: phase, config: config)
                shadowOp = shadowOpacity(forPhase: phase, config: config)
            }

            if slot.colorState == .unavailable && slot.instanceType.isBalance {
                let naWidth = textWidth("N/A", font: Self.font)
                let naX = slotOriginX + (slotWidth - naWidth) / 2
                renderText("N/A", at: CGPoint(x: naX, y: centerBaseline), color: renderColor, font: Self.font, in: context)
                continue
            }

            renderTwoLineSlot(
                atX: slotOriginX,
                width: slotWidth,
                data: slot,
                color: renderColor,
                in: context,
                shadowBlurRadius: shadowBlur,
                shadowOpacity: shadowOp
            )
        }

        image.unlockFocus()
        return image
    }

    func updateBreathingState(slotViewDataList: [SlotViewData]) {
        let expandedSlots = expandToMetricSlots(slotViewDataList)

        // `colorState` is independent of `isStale` — a stale warning/critical
        // slot still reports `.warning` / `.critical` here, so it keeps
        // pulsing. Staleness is signaled separately by the 80% alpha overlay
        // applied in the main render loop.
        let breathingUUIDs = Set(expandedSlots
            .filter { $0.colorState == .warning || $0.colorState == .critical }
            .map { $0.uuid })

        breathingSlots = breathingUUIDs
    }

    func needsBreathingAnimation() -> Bool {
        return !breathingSlots.isEmpty
    }

    func startBreathingAnimation() {
        guard breathingTimer == nil else { return }
        breathingStartTime = currentTimeProvider()
        breathingTimer = Timer.scheduledTimer(withTimeInterval: Self.breathingAnimationInterval, repeats: true) { [weak self] _ in
            self?.onNeedsDisplay?()
        }
    }

    func stopBreathingAnimation() {
        breathingTimer?.invalidate()
        breathingTimer = nil
    }

    func isBreathingAnimationRunning() -> Bool {
        return breathingTimer != nil
    }

    // MARK: - Default Animation Lifecycle

    var isDefaultAnimationRunning: Bool { defaultAnimationTimer != nil }

    func startDefaultAnimation() {
        guard defaultAnimationTimer == nil else { return }
        defaultAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.advanceDefaultAnimationCycle()
        }
    }

    func stopDefaultAnimation() {
        defaultAnimationTimer?.invalidate()
        defaultAnimationTimer = nil
    }

    // MARK: - Peak Timer Lifecycle
    //
    // 60 s tick that drives `onNeedsDisplay` so the DeepSeek slot's peak
    // overlay (or lack thereof) is recomputed and redrawn at the BJT
    // window boundaries. `PeakSchedule.isPeak()` is read fresh on every
    // redraw inside `render(...)`, so no cached state needs invalidation
    // here — the timer is purely a wake-up mechanism.
    //
    // Differs from `breathingTimer` (0.5 s) and `defaultAnimationTimer` (1 s):
    // those fire frequently enough that user interaction constantly re-arms
    // the run loop. A 60 s timer that only matters near hourly boundaries
    // is far more exposed to App Nap throttling, so this one is registered
    // on the `.common` run-loop mode to keep it alive through modal loops
    // and reduce idle coalescing. This is the lightest-weight mitigation
    // — full NSActivity assertions are not needed for a hint-grade label.
    //
    // **Verification status**: the `.common` mode + 60 s cadence was
    // chosen as a pragmatic balance. It has not been empirically validated
    // against App Nap throttling under prolonged idle (the project is
    // currently investigating App Nap elsewhere — see
    // commit `4bfb5a7 chore(diagnostics): instrument refresh cycle +
    // lifecycle for App Nap investigation`). If the overlay stops
    // flipping during a BJT boundary transition in a long-idle session,
    // wrap `startPeakTimer`'s `Timer` body with a short-lived
    // `ProcessInfo.processInfo.beginActivity(options: .userInitiated, ...)`
    // assertion. See `docs/provider-interfaces/deepseek.md` §11.4.
    //
    // **Dual `isPeak()` evaluation is intentional**: this 60 s timer
    // wakes *this* render path; `UsageCardView.balanceContent` evaluates
    // `PeakSchedule.isPeak()` independently inside
    // `TimelineView(.periodic(by: 60))`. Each path renders on its own
    // cadence without sharing state — sharing a published `@Published`
    // would couple the menu-bar's freshness model to the SwiftUI view
    // tree's lifetime, and is not worth that coupling for a hint.

    func startPeakTimer() {
        guard peakTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.onNeedsDisplay?()
        }
        RunLoop.main.add(timer, forMode: .common)
        peakTimer = timer
    }

    func stopPeakTimer() {
        // `Timer.invalidate()` removes the timer from every run loop it was
        // added to, so no explicit `RunLoop.main.remove` is needed.
        peakTimer?.invalidate()
        peakTimer = nil
    }

    func isPeakTimerRunning() -> Bool {
        return peakTimer != nil
    }

    // MARK: - Private: measurement

    /// Expand each `SlotViewData` into per-metric render slots so that each
    /// visible metric gets its own icon slot.
    ///
    /// - When `metricSnapshots` is non-empty, each snapshot with
    ///   `displayInMenuBar == true` becomes one slot (1 metric = 1 slot).
    ///   Slots are ordered by Instance `sortOrder` then `configIndex`.
    /// - When `metricSnapshots` is empty, backward compat: one slot per instance.
    /// - Disabled colour-state slots are excluded in both paths.
    private func expandToMetricSlots(_ slotViewDataList: [SlotViewData]) -> [SlotViewData] {
        var expanded: [SlotViewData] = []
        for slot in slotViewDataList {
            // Capture staleness from the source slot BEFORE constructing
            // the expanded metric slot. The expanded slot's computed
            // `colorState` reflects the snapshot's threshold (independent
            // of `isStale`), so we forward `isStale` explicitly via the
            // `isStaleSource` parameter below.
            let isStaleSource = slot.isStale
            let snapshots = slot.metricSnapshots
            if snapshots.isEmpty {
                if slot.colorState != .disabled {
                    expanded.append(slot)
                }
            } else {
                for snapshot in snapshots {
                    guard snapshot.displayInMenuBar else { continue }
                    guard snapshot.colorState != .disabled else { continue }
                    expanded.append(SlotViewData(
                        uuid: "\(slot.uuid)/\(snapshot.key)",
                        displayName: snapshot.group ?? slot.displayName,
                        shortName: snapshot.shortName ?? slot.shortName,
                        instanceType: slot.instanceType,
                        sortOrder: slot.sortOrder * 10000 + snapshot.configIndex,
                        colorState: slot.colorState,
                        provider: slot.provider,
                        metricSnapshots: [snapshot],
                        isStale: isStaleSource
                    ))
                }
            }
        }
        expanded.sort { $0.sortOrder < $1.sortOrder }
        return expanded
    }

    private func measureSlotContent(_ slot: SlotViewData) -> CGFloat {
        let shortName = String(slot.shortName.uppercased().prefix(3))
        let nameWidth = textWidth(shortName, font: Self.font)

        let valueWidth: CGFloat
        switch slot.instanceType {
        case .quota(let percent, _, _, _):
            valueWidth = slot.metricSnapshots.first?.isUnlimited == true
                ? textWidth("∞", font: Self.monoFont)
                : textWidth("\(Int(percent))%", font: Self.monoFont)
        case .balance(let amount, _, _, _, let currency):
            let symbol = currency?.currencySymbol ?? "¥"
            valueWidth = textWidth(symbol + balanceInt(amount), font: Self.font)
        }

        return max(nameWidth, valueWidth)
    }

    // MARK: - Private: colors

    private func colorForSlot(_ slot: SlotViewData, colorMode: ColorMode, isDarkBackground: Bool) -> NSColor {
        // `colorState` is independent of `isStale` — stale slots report their
        // true threshold (e.g. `.warning`). Staleness is layered on top via
        // the 80% alpha overlay in the main render loop, so this function
        // only needs to handle the threshold color logic.
        switch slot.colorState {
        case .disabled, .unavailable, .loading, .error:
            return Self.dimColor
        case .normal, .warning, .critical:
            break
        }

        switch colorMode {
        case .monochrome:
            return isDarkBackground ? .white : .black
        case .color:
            switch slot.colorState {
            case .normal:    return Self.safeColor
            case .warning:   return Self.warningColor
            case .critical:  return Self.criticalColor
            default:         return Self.dimColor
            }
        }
    }

    // MARK: - Private: default state rendering (two-line animated)

    private func renderDefaultState(colorMode: ColorMode, isDarkBackground: Bool) -> NSImage {
        let topText = "AI"
        let bottomText = Self.defaultAnimationTexts[defaultAnimationCycleIndex]

        let textColor: NSColor = {
            switch colorMode {
            case .monochrome:
                return isDarkBackground ? .white : .black
            case .color:
                return Self.safeColor
            }
        }()

        let topWidth = textWidth(topText, font: Self.font)
        let bottomWidth = textWidth(Self.defaultAnimationTexts.last!, font: Self.monoFont)
        let width = max(topWidth, bottomWidth)

        let size = NSSize(width: width, height: Self.slotHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            let (topBaseline, bottomBaseline) = twoLineBaselines

            let topX = (width - topWidth) / 2
            renderText(topText, at: CGPoint(x: topX, y: topBaseline), color: textColor, font: Self.font, in: context)

            let bottomX = width - textWidth(bottomText, font: Self.monoFont)
            renderText(bottomText, at: CGPoint(x: bottomX, y: bottomBaseline), color: textColor, font: Self.monoFont, in: context)
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Private: special state rendering (single centred line)

    private func renderSpecialCenteredText(
        _ text: String,
        shadowBlurRadius: CGFloat = 0,
        shadowOpacity: CGFloat = 0
    ) -> NSImage {
        let width = textWidth(text, font: Self.font)
        let size = NSSize(width: width, height: Self.slotHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            let tw = textWidth(text, font: Self.font)
            let x = (width - tw) / 2

            if shadowBlurRadius > 0 && shadowOpacity > 0 {
                context.saveGState()
                context.setShadow(offset: CGSize.zero, blur: shadowBlurRadius,
                                  color: Self.dimColor.withAlphaComponent(shadowOpacity).cgColor)
            }

            renderText(text, at: CGPoint(x: x, y: centerBaseline), color: Self.dimColor, font: Self.font, in: context)

            if shadowBlurRadius > 0 && shadowOpacity > 0 {
                context.restoreGState()
            }
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Private: helpers

    /// Truncate decimal portion for menu-bar display (internal logic keeps full precision).
    private func balanceInt(_ amount: String) -> String {
        guard let value = Double(amount) else { return amount }
        return String(Int(value))
    }

    private func textWidth(_ text: String, font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return (text as NSString).size(withAttributes: attributes).width
    }

    @discardableResult
    private func renderText(
        _ text: String,
        at position: CGPoint,
        color: NSColor,
        font: NSFont,
        in context: CGContext
    ) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: position, withAttributes: attributes)
        return position.x + size.width
    }

    // MARK: - Baseline calculations

    /// Baseline for a single centred line in 22pt height.
    /// Uses capHeight so the glyph (not typographic bounds) is centred.
    private var centerBaseline: CGFloat {
        let f = Self.font
        return (Self.slotHeight - f.capHeight) / 2
    }

    /// Baseline pair for two-line stacked layout.
    /// Uses capHeight (visual height of uppercase text) with a downward bias
    /// so the visible glyph block sits slightly below geometric centre.
    private var twoLineBaselines: (top: CGFloat, bottom: CGFloat) {
        let f = Self.font
        let capH = f.capHeight
        let midGap: CGFloat = 2.0

        let visualBlockHeight = capH * 2 + midGap
        let totalPadding = Self.slotHeight - visualBlockHeight
        let halfPadding = totalPadding / 2

        let bias: CGFloat = 1.5
        let bottom = halfPadding - bias
        let top = bottom + capH + midGap
        return (top: top, bottom: bottom)
    }

    // MARK: - Private: two-line slot rendering (fresh)

    /// Plain-text two-line slot for fresh (non-stale) data. Optional
    /// breathing shadow is applied around the text renders when active
    /// (caller passes 0/0 to disable).
    ///
    /// DeepSeek peak overlay: when this slot's provider is DeepSeek and the
    /// current moment is in peak (per `PeakSchedule.isPeak()`), fill a
    /// rounded-rect background behind the slot and render the text in the
    /// WARN palette (yellow on yellow = the user's "inverted" requirement).
    /// Off-peak slots fall through to the unmodified rendering path. The
    /// `MenuBarController` ticks a 60 s timer that calls `onNeedsDisplay`
    /// so this overlay flips at the BJT window boundaries without caching
    /// any state in the renderer.
    private func renderTwoLineSlot(
        atX originX: CGFloat,
        width: CGFloat,
        data: SlotViewData,
        color: NSColor,
        in context: CGContext,
        shadowBlurRadius: CGFloat = 0,
        shadowOpacity: CGFloat = 0
    ) {
        let isDeepSeek = data.provider == Provider.deepseek.rawValue
        let inPeak = isDeepSeek && PeakSchedule.isPeak() == .peak
        let textColor = inPeak ? Self.warningColor : color

        if inPeak {
            // Rounded-rect background drawn before the shadow state is
            // pushed — we don't want the shadow under the bg fill, only
            // around the text that sits on top of it.
            let padX: CGFloat = 3
            let cornerRadius: CGFloat = 3
            let rect = CGRect(
                x: originX - padX,
                y: 0,
                width: width + padX * 2,
                height: Self.slotHeight
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.menuBarPeakBg.setFill()
            path.fill()
        }

        let shortName = String(data.shortName.uppercased().prefix(3))
        let (topBaseline, bottomBaseline) = twoLineBaselines

        if shadowBlurRadius > 0 && shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize.zero,
                blur: shadowBlurRadius,
                color: textColor.withAlphaComponent(shadowOpacity).cgColor
            )
        }

        let nameWidth = textWidth(shortName, font: Self.font)
        let nameX = originX + (width - nameWidth) / 2
        renderText(shortName, at: CGPoint(x: nameX, y: topBaseline), color: textColor, font: Self.font, in: context)

        let valueText: String
        let valueFont: NSFont
        switch data.instanceType {
        case .quota(let percent, _, _, _):
            valueFont = Self.monoFont
            valueText = data.metricSnapshots.first?.isUnlimited == true
                ? "∞"
                : "\(Int(percent))%"
        case .balance(let amount, _, _, _, let currency):
            let symbol = currency?.currencySymbol ?? "¥"
            valueText = symbol + balanceInt(amount)
            valueFont = Self.font
        }

        let valueWidth = textWidth(valueText, font: valueFont)
        let valueX = originX + (width - valueWidth) / 2
        renderText(valueText, at: CGPoint(x: valueX, y: bottomBaseline), color: textColor, font: valueFont, in: context)

        if shadowBlurRadius > 0 && shadowOpacity > 0 {
            context.restoreGState()
        }
    }

    deinit {
        breathingTimer?.invalidate()
        defaultAnimationTimer?.invalidate()
        peakTimer?.invalidate()
    }
}
