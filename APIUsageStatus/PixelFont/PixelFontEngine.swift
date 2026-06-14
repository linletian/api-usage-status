// ⚠️ DEPRECATED. Original pixel font rendering engine; no longer needed since menu bar reverted to system fonts (SF Pro 10pt).
// Kept for historical reference; to be removed later. See ARCHITECTURE.md §2.11 / ADR-003.
#if false

import AppKit

// MARK: - CharSize

enum CharSize {
    case letter // 5×7
    case digit  // 3×5

    var cols: Int {
        switch self {
        case .letter: return 5
        case .digit:  return 3
        }
    }

    var rows: Int {
        switch self {
        case .letter: return 7
        case .digit:  return 5
        }
    }
}

// MARK: - PixelFontEngine

/// Pure function module for rendering pixel font text into a CGContext.
/// The caller supplies the `scale` dynamically based on the screen resolution.
enum PixelFontEngine {

    // MARK: - Constants (screen-independent)

    /// Horizontal gap between individual characters (in pt).
    static let charGap: CGFloat = 1.0

    /// Horizontal gap between distinct UI elements inside a slot.
    static let elementGap: CGFloat = 2.0

    /// Total slot height in pt.
    static let slotHeight: CGFloat = 22.0

    // MARK: - Character lookup

    static func bitmap(for char: Character, size: CharSize) -> [[Bool]]? {
        let upper = Character(char.uppercased())
        switch size {
        case .letter:
            return CharMapLetters.map[upper]
        case .digit:
            return CharMapDigits.map[char]
        }
    }

    // MARK: - Single character rendering

    static func renderChar(
        _ char: Character,
        size: CharSize,
        at origin: CGPoint,
        color: NSColor,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard let bitmap = bitmap(for: char, size: size) else { return }
        let rows = size.rows

        // Vertically centre the character within the slot
        let charHeight = CGFloat(rows) * scale
        let baseY = origin.y + (PixelFontEngine.slotHeight - charHeight) / 2

        context.setFillColor(color.cgColor)

        for (row, line) in bitmap.enumerated() {
            for (col, isLit) in line.enumerated() where isLit {
                // Bitmap row 0 is visual top → flip when drawing from bottom origin
                let x = origin.x + CGFloat(col) * scale
                let y = baseY + CGFloat(rows - 1 - row) * scale
                let rect = CGRect(
                    x: round(x),
                    y: round(y),
                    width: scale,
                    height: scale
                )
                context.fill(rect)
            }
        }
    }

    // MARK: - Text string rendering

    @discardableResult
    static func renderText(
        _ text: String,
        at origin: CGPoint,
        color: NSColor,
        scale: CGFloat,
        in context: CGContext
    ) -> CGFloat {
        var cursorX = origin.x
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            let size: CharSize = char.isNumber ? .digit : .letter
            renderChar(char, size: size, at: CGPoint(x: cursorX, y: origin.y), color: color, scale: scale, in: context)
            var advance = CGFloat(size.cols) * scale
            if index < chars.count - 1 {
                advance += PixelFontEngine.charGap
            }
            cursorX += advance
        }
        return cursorX
    }

    /// Compute the total width of a text string (in pt).
    static func textWidth(_ text: String, scale: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        let chars = Array(text)
        for (index, char) in chars.enumerated() {
            let size: CharSize = char.isNumber ? .digit : .letter
            width += CGFloat(size.cols) * scale
            if index < chars.count - 1 {
                width += PixelFontEngine.charGap
            }
        }
        return width
    }

    // MARK: - Progress bar rendering

    static func renderProgressBar(
        at origin: CGPoint,
        width: CGFloat = 14,
        height: CGFloat = 4,
        percent: Double,
        color: NSColor,
        in context: CGContext
    ) {
        let barFrame = CGRect(x: round(origin.x), y: round(origin.y), width: width, height: height)

        // Outline (1 pt stroke)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        context.stroke(barFrame)

        // Fill logic based on percentage bands
        let fillRatio: CGFloat
        if percent <= 50 {
            fillRatio = 0
        } else if percent <= 80 {
            fillRatio = 0.5
        } else {
            fillRatio = 1.0
        }

        if fillRatio > 0 {
            let interiorHeight = barFrame.height - 2
            let fillHeight = interiorHeight * fillRatio
            let fillRect = CGRect(
                x: barFrame.minX + 1,
                y: barFrame.minY + 1,
                width: max(0, barFrame.width - 2),
                height: max(0, fillHeight)
            )
            context.setFillColor(color.cgColor)
            context.fill(fillRect)
        }
    }

    // MARK: - Slot rendering

    @discardableResult
    static func renderSlot(
        at origin: CGPoint,
        data: SlotViewData,
        color: NSColor,
        scale: CGFloat,
        in context: CGContext
    ) -> CGFloat {
        var cursorX = origin.x

        // Short name (always 2 letters, 5×7)
        let shortName = data.shortName.uppercased().prefix(2)
        let nameText = String(shortName)
        let nameWidth = textWidth(nameText, scale: scale)
        _ = renderText(nameText, at: CGPoint(x: cursorX, y: origin.y), color: color, scale: scale, in: context)
        cursorX += nameWidth
        cursorX += PixelFontEngine.elementGap

        switch data.instanceType {
        case .quota(let percent, _, _, _):
            // Progress bar (14×4 pt), vertically centred in 22 pt slot
            let barY = origin.y + (PixelFontEngine.slotHeight - 4) / 2
            renderProgressBar(
                at: CGPoint(x: cursorX, y: barY),
                width: 14,
                height: 4,
                percent: percent,
                color: color,
                in: context
            )
            cursorX += 14
            cursorX += PixelFontEngine.elementGap

            // Percentage number (3×5 digits) + "%" symbol (5×7)
            let percentText = "\(Int(percent))"
            let numWidth = textWidth(percentText, scale: scale)
            _ = renderText(percentText, at: CGPoint(x: cursorX, y: origin.y), color: color, scale: scale, in: context)
            cursorX += numWidth
            // Percent sign rendered as a letter
            renderChar("%", size: .letter, at: CGPoint(x: cursorX, y: origin.y), color: color, scale: scale, in: context)
            cursorX += CGFloat(CharSize.letter.cols) * scale

        case .balance(let amount, _, _, _, let currency):
            // Currency symbol (5×7 letter) + amount digits (3×5)
            let symbol = currency?.currencySymbol ?? "¥"
            let balanceText = symbol + amount
            let balWidth = textWidth(balanceText, scale: scale)
            _ = renderText(balanceText, at: CGPoint(x: cursorX, y: origin.y), color: color, scale: scale, in: context)
            cursorX += balWidth
        }

        return cursorX - origin.x
    }
}

#endif // false
