import AppKit
import Combine

// MARK: - MenuBarIconRenderer

/// Renders the menu-bar icon as a pixel-perfect NSImage.
/// Must be called on the main actor because it uses NSImage.lockFocus().
@MainActor
final class MenuBarIconRenderer {

    // MARK: - Colour constants

    private static let dimColor       = NSColor(red: 0.839, green: 0.816, blue: 0.627, alpha: 1.0) // #D6D0A0
    private static let safeColor      = NSColor(red: 0.298, green: 0.686, blue: 0.314, alpha: 1.0) // #4CAF50
    private static let warningColor   = NSColor(red: 1.000, green: 0.757, blue: 0.027, alpha: 1.0) // #FFC107
    private static let criticalColor  = NSColor(red: 0.957, green: 0.263, blue: 0.212, alpha: 1.0) // #F44336

    // MARK: - Flashing state

    /// Structured-concurrency replacement for Timer; cancellable automatically
    /// when the renderer is deallocated or when no critical slots remain.
    private var flashingTask: Task<Void, Never>?

    /// Keyed by slot uuid so re-ordering / deletion never shifts state to the wrong slot.
    private var flashingVisible: [String: Bool] = [:]

    /// Called whenever the renderer needs the owner to repaint the status item.
    var onNeedsDisplay: (() -> Void)?

    // MARK: - Dynamic scale

    /// Determines the pixel scale based on screen resolution.
    /// - 1x (non-Retina): scale = 2.0 so each logical pixel is 2×2 pt → readable.
    /// - 2x/3x (Retina):  scale = 1.0 so each logical pixel is 1×1 pt → Retina auto-doubles.
    private func resolveScale() -> CGFloat {
        let backing = NSScreen.main?.backingScaleFactor ?? 2.0
        return backing > 1.0 ? 1.0 : 2.0
    }

    // MARK: - Public API

    /// Generates the current menu-bar icon image.
    func render(
        slotViewDataList: [SlotViewData],
        colorMode: ColorMode,
        refreshState: RefreshState,
        instancesCount: Int,
        enabledCount: Int
    ) -> NSImage {
        let scale = resolveScale()

        // Determine content
        if instancesCount == 0 {
            return renderSpecialText("?", color: MenuBarIconRenderer.dimColor, scale: scale)
        }

        if enabledCount == 0 {
            return renderSpecialText("NO API", color: MenuBarIconRenderer.dimColor, scale: scale)
        }

        if refreshState == .refreshing && slotViewDataList.isEmpty {
            return renderSpecialText("\u{2022}\u{2022}\u{2022}", color: MenuBarIconRenderer.dimColor, scale: scale)
        }

        // Normal state: render up to 2 enabled slots
        let enabledSlots = slotViewDataList
            .filter { $0.colorState != .disabled }
            .sorted { $0.sortOrder < $1.sortOrder }
            .prefix(2)

        if enabledSlots.isEmpty {
            return renderSpecialText("?", color: MenuBarIconRenderer.dimColor, scale: scale)
        }

        // Calculate total width
        let slotGap: CGFloat = 2
        var totalWidth: CGFloat = 0
        var slotWidths: [CGFloat] = []
        for slot in enabledSlots {
            let isVisible = flashingVisible[slot.uuid] ?? true

            if slot.colorState == .critical && !isVisible {
                let w = measureSlot(slot, scale: scale)
                slotWidths.append(w)
            } else if slot.colorState == .unavailable && slot.instanceType.isBalance {
                let w = PixelFontEngine.textWidth("N/A", scale: scale)
                slotWidths.append(w)
            } else {
                let w = measureSlot(slot, scale: scale)
                slotWidths.append(w)
            }

            totalWidth += slotWidths[slotWidths.count - 1]
            if slotWidths.count < enabledSlots.count {
                totalWidth += slotGap
            }
        }

        // Create image
        let size = NSSize(width: totalWidth, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        var cursorX: CGFloat = 0
        for (slot, slotWidth) in zip(enabledSlots, slotWidths) {
            let isVisible = flashingVisible[slot.uuid] ?? true
            let slotColor = colorForSlot(slot, colorMode: colorMode)

            if slot.colorState == .critical && !isVisible {
                // Skip rendering this slot (flashing off)
            } else if slot.colorState == .unavailable && slot.instanceType.isBalance {
                _ = PixelFontEngine.renderText("N/A", at: CGPoint(x: cursorX, y: 0), color: slotColor, scale: scale, in: context)
            } else {
                _ = PixelFontEngine.renderSlot(at: CGPoint(x: cursorX, y: 0), data: slot, color: slotColor, scale: scale, in: context)
            }

            cursorX += slotWidth + slotGap
        }

        image.unlockFocus()
        return image
    }

    /// Call this whenever new slot data arrives so flashing tasks can start / stop.
    func updateFlashingState(slotViewDataList: [SlotViewData]) {
        let enabledSlots = slotViewDataList
            .filter { $0.colorState != .disabled }
            .sorted { $0.sortOrder < $1.sortOrder }
            .prefix(2)

        let currentCriticalUUIDs = Set(enabledSlots
            .filter { $0.colorState == .critical }
            .map { $0.uuid })

        // 1. Remove entries for slots that are no longer critical (disabled / deleted / recovered)
        for uuid in flashingVisible.keys {
            if !currentCriticalUUIDs.contains(uuid) {
                flashingVisible.removeValue(forKey: uuid)
            }
        }

        // 2. Add entries for newly-critical slots (default visible so they appear immediately)
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

    // MARK: - Private helpers

    private func measureSlot(_ slot: SlotViewData, scale: CGFloat) -> CGFloat {
        var width: CGFloat = 0

        // Short name
        let shortName = slot.shortName.uppercased().prefix(2)
        width += PixelFontEngine.textWidth(String(shortName), scale: scale)
        width += PixelFontEngine.elementGap

        switch slot.instanceType {
        case .quota(let percent, _, _, _, _):
            // Progress bar
            width += 14
            width += PixelFontEngine.elementGap
            // Percent text (digits + % sign)
            let percentText = "\(Int(percent))"
            width += PixelFontEngine.textWidth(percentText, scale: scale)
            width += CGFloat(CharSize.letter.cols) * scale // % sign

        case .balance(let amount, _, _, _, let currency):
            let symbol = currency?.currencySymbol ?? "¥"
            let balanceText = symbol + amount
            width += PixelFontEngine.textWidth(balanceText, scale: scale)
        }

        return width
    }

    private func colorForSlot(_ slot: SlotViewData, colorMode: ColorMode) -> NSColor {
        switch slot.colorState {
        case .disabled, .unavailable, .loading, .error:
            return MenuBarIconRenderer.dimColor
        case .normal, .warning, .critical:
            break
        }

        switch colorMode {
        case .monochrome:
            return NSColor.labelColor
        case .color:
            switch slot.colorState {
            case .normal:    return MenuBarIconRenderer.safeColor
            case .warning:   return MenuBarIconRenderer.warningColor
            case .critical:  return MenuBarIconRenderer.criticalColor
            default:         return MenuBarIconRenderer.dimColor
            }
        }
    }

    private func renderSpecialText(_ text: String, color: NSColor, scale: CGFloat) -> NSImage {
        let width = PixelFontEngine.textWidth(text, scale: scale)
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            _ = PixelFontEngine.renderText(text, at: CGPoint(x: 0, y: 0), color: color, scale: scale, in: context)
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Flashing task (structured-concurrency replacement for Timer)

    private func startFlashingTask() {
        flashingTask?.cancel()
        flashingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                // Only toggle slots that are still marked as critical in flashingVisible.
                // If updateFlashingState removed a uuid, it simply won't be toggled any more.
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
