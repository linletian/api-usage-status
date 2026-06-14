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

    private static let dimColor       = NSColor(red: 0.839, green: 0.816, blue: 0.627, alpha: 1.0) // #D6D0A0
    private static let safeColor      = NSColor(red: 0.298, green: 0.686, blue: 0.314, alpha: 1.0) // #4CAF50
    private static let warningColor   = NSColor(red: 1.000, green: 0.757, blue: 0.027, alpha: 1.0) // #FFC107
    private static let criticalColor  = NSColor(red: 0.957, green: 0.263, blue: 0.212, alpha: 1.0) // #F44336

    // MARK: - Font constants

    /// Regular-weight SF Pro at 8pt — two lines fit in 22pt slot height.
    private static let font     = NSFont.systemFont(ofSize: 8)

    /// Monospaced variant for percentage digits so slot width stays stable.
    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)

    // MARK: - Layout constants

    private static let slotHeight: CGFloat = 22.0

    /// Horizontal gap between adjacent slots.
    private static let betweenSlotGap: CGFloat = 10.0

    // MARK: - Flashing state

    private var flashingTask: Task<Void, Never>?
    private var flashingVisible: [String: Bool] = [:]

    var onNeedsDisplay: (() -> Void)?

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
            return renderSpecialCenteredText("?")
        }
        if enabledCount == 0 {
            return renderSpecialCenteredText("NO API")
        }
        if refreshState == .refreshing && slotViewDataList.isEmpty {
            return renderSpecialCenteredText("\u{2022}\u{2022}\u{2022}")
        }

        let enabledSlots = slotViewDataList
            .filter { $0.colorState != .disabled }
            .sorted { $0.sortOrder < $1.sortOrder }

        if enabledSlots.isEmpty {
            return renderSpecialCenteredText("?")
        }

        // Per-slot content width: each slot is sized by its own content, no equal-width forcing.
        let slotWidths: [CGFloat] = enabledSlots.map { slot in
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
        for (index, slot) in enabledSlots.enumerated() {
            let slotWidth = slotWidths[index]
            let isVisible = flashingVisible[slot.uuid] ?? true

            defer { slotOriginX += slotWidth + Self.betweenSlotGap }

            if slot.colorState == .critical && !isVisible {
                continue
            }

            let slotColor = colorForSlot(slot, colorMode: colorMode, isDarkBackground: isDarkBackground)

            if slot.colorState == .unavailable && slot.instanceType.isBalance {
                let naWidth = textWidth("N/A", font: Self.font)
                let naX = slotOriginX + (slotWidth - naWidth) / 2
                renderText("N/A", at: CGPoint(x: naX, y: centerBaseline), color: slotColor, font: Self.font, in: context)
            } else {
                renderTwoLineSlot(atX: slotOriginX, width: slotWidth, data: slot, color: slotColor, in: context)
            }
        }

        image.unlockFocus()
        return image
    }

    func updateFlashingState(slotViewDataList: [SlotViewData]) {
        let enabledSlots = slotViewDataList
            .filter { $0.colorState != .disabled }
            .sorted { $0.sortOrder < $1.sortOrder }

        let currentCriticalUUIDs = Set(enabledSlots
            .filter { $0.colorState == .critical }
            .map { $0.uuid })

        for uuid in flashingVisible.keys {
            if !currentCriticalUUIDs.contains(uuid) {
                flashingVisible.removeValue(forKey: uuid)
            }
        }

        for slot in enabledSlots where slot.colorState == .critical {
            if flashingVisible[slot.uuid] == nil {
                flashingVisible[slot.uuid] = true
            }
        }

        let hasCritical = !flashingVisible.isEmpty
        if hasCritical && flashingTask == nil {
            startFlashingTask()
        } else if !hasCritical {
            stopFlashingTask()
        }
    }

    // MARK: - Private: measurement

    private func measureSlotContent(_ slot: SlotViewData) -> CGFloat {
        let shortName = String(slot.shortName.uppercased().prefix(2))
        let nameWidth = textWidth(shortName, font: Self.font)

        let valueWidth: CGFloat
        switch slot.instanceType {
        case .quota(let percent, _, _, _):
            valueWidth = textWidth("\(Int(percent))%", font: Self.monoFont)
        case .balance(let amount, _, _, _, let currency):
            let symbol = currency?.currencySymbol ?? "¥"
            valueWidth = textWidth(symbol + balanceInt(amount), font: Self.font)
        }

        return max(nameWidth, valueWidth)
    }

    // MARK: - Private: colors

    private func colorForSlot(_ slot: SlotViewData, colorMode: ColorMode, isDarkBackground: Bool) -> NSColor {
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

    // MARK: - Private: special state rendering (single centred line)

    private func renderSpecialCenteredText(_ text: String) -> NSImage {
        let width = textWidth(text, font: Self.font)
        let size = NSSize(width: width, height: Self.slotHeight)
        let image = NSImage(size: size)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            let tw = textWidth(text, font: Self.font)
            let x = (width - tw) / 2
            renderText(text, at: CGPoint(x: x, y: centerBaseline), color: Self.dimColor, font: Self.font, in: context)
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

    // MARK: - Private: two-line slot rendering

    private func renderTwoLineSlot(
        atX originX: CGFloat,
        width: CGFloat,
        data: SlotViewData,
        color: NSColor,
        in context: CGContext
    ) {
        let shortName = String(data.shortName.uppercased().prefix(2))
        let (topBaseline, bottomBaseline) = twoLineBaselines

        // Line 1: shortName
        let nameWidth = textWidth(shortName, font: Self.font)
        let nameX = originX + (width - nameWidth) / 2
        renderText(shortName, at: CGPoint(x: nameX, y: topBaseline), color: color, font: Self.font, in: context)

        // Line 2: value
        let valueText: String
        let valueFont: NSFont
        switch data.instanceType {
        case .quota(let percent, _, _, _):
            valueText = "\(Int(percent))%"
            valueFont = Self.monoFont
        case .balance(let amount, _, _, _, let currency):
            let symbol = currency?.currencySymbol ?? "¥"
            valueText = symbol + balanceInt(amount)
            valueFont = Self.font
        }

        let valueWidth = textWidth(valueText, font: valueFont)
        let valueX = originX + (width - valueWidth) / 2
        renderText(valueText, at: CGPoint(x: valueX, y: bottomBaseline), color: color, font: valueFont, in: context)
    }

    // MARK: - Flashing task

    private func startFlashingTask() {
        flashingTask?.cancel()
        flashingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                for uuid in self.flashingVisible.keys {
                    self.flashingVisible[uuid]?.toggle()
                }
                self.onNeedsDisplay?()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopFlashingTask() {
        flashingTask?.cancel()
        flashingTask = nil
        flashingVisible.removeAll()
    }

    deinit {
        flashingTask?.cancel()
    }
}
