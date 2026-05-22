// ⚠️ 本测试文件已弃用。原像素字模引擎的单元测试，因引擎代码已注释而不再运行。
// 代码保留供历史参考，待后续彻底删除。
#if false

import XCTest
@testable import APIUsageStatus

// MARK: - PixelFontEngineTests

/// Tests for the pixel-font rendering engine.
/// Covers all 43 characters (A-Z, 0-9, 7 symbols), text composition,
/// progress-bar fill logic, and unknown-character graceful handling.
final class PixelFontEngineTests: XCTestCase {

    // MARK: - Character bitmap lookup

    func testAllLettersPresent() {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        for char in letters {
            XCTAssertNotNil(
                PixelFontEngine.bitmap(for: char, size: .letter),
                "Letter \(char) should have a bitmap"
            )
        }
    }

    func testAllDigitsPresent() {
        let digits = "0123456789"
        for char in digits {
            XCTAssertNotNil(
                PixelFontEngine.bitmap(for: char, size: .digit),
                "Digit \(char) should have a bitmap"
            )
        }
    }

    func testAllSymbolsPresent() {
        let symbols: [Character] = ["%", "¥", "$", ".", "?", "\u{2022}", "/"]
        for char in symbols {
            XCTAssertNotNil(
                PixelFontEngine.bitmap(for: char, size: .letter),
                "Symbol \(char) should have a bitmap"
            )
        }
    }

    func testBitmapDimensions() {
        // Letters: 5 cols × 7 rows
        if let a = PixelFontEngine.bitmap(for: "A", size: .letter) {
            XCTAssertEqual(a.count, 7)
            XCTAssertEqual(a[0].count, 5)
        }
        // Digits: 3 cols × 5 rows
        if let zero = PixelFontEngine.bitmap(for: "0", size: .digit) {
            XCTAssertEqual(zero.count, 5)
            XCTAssertEqual(zero[0].count, 3)
        }
    }

    func testUnknownCharacterReturnsNil() {
        XCTAssertNil(PixelFontEngine.bitmap(for: "1", size: .letter))
        XCTAssertNil(PixelFontEngine.bitmap(for: "@", size: .letter))
        XCTAssertNil(PixelFontEngine.bitmap(for: "A", size: .digit))
    }

    // MARK: - Single-character pixel-perfect rendering

    // MARK: Letters A-Z (26 characters)
    func testRenderCharLetterA() { assertCharRenderedAccurately("A", size: .letter, scale: 2.0) }
    func testRenderCharLetterB() { assertCharRenderedAccurately("B", size: .letter, scale: 2.0) }
    func testRenderCharLetterC() { assertCharRenderedAccurately("C", size: .letter, scale: 2.0) }
    func testRenderCharLetterD() { assertCharRenderedAccurately("D", size: .letter, scale: 2.0) }
    func testRenderCharLetterE() { assertCharRenderedAccurately("E", size: .letter, scale: 2.0) }
    func testRenderCharLetterF() { assertCharRenderedAccurately("F", size: .letter, scale: 2.0) }
    func testRenderCharLetterG() { assertCharRenderedAccurately("G", size: .letter, scale: 2.0) }
    func testRenderCharLetterH() { assertCharRenderedAccurately("H", size: .letter, scale: 2.0) }
    func testRenderCharLetterI() { assertCharRenderedAccurately("I", size: .letter, scale: 2.0) }
    func testRenderCharLetterJ() { assertCharRenderedAccurately("J", size: .letter, scale: 2.0) }
    func testRenderCharLetterK() { assertCharRenderedAccurately("K", size: .letter, scale: 2.0) }
    func testRenderCharLetterL() { assertCharRenderedAccurately("L", size: .letter, scale: 2.0) }
    func testRenderCharLetterM() { assertCharRenderedAccurately("M", size: .letter, scale: 2.0) }
    func testRenderCharLetterN() { assertCharRenderedAccurately("N", size: .letter, scale: 2.0) }
    func testRenderCharLetterO() { assertCharRenderedAccurately("O", size: .letter, scale: 2.0) }
    func testRenderCharLetterP() { assertCharRenderedAccurately("P", size: .letter, scale: 2.0) }
    func testRenderCharLetterQ() { assertCharRenderedAccurately("Q", size: .letter, scale: 2.0) }
    func testRenderCharLetterR() { assertCharRenderedAccurately("R", size: .letter, scale: 2.0) }
    func testRenderCharLetterS() { assertCharRenderedAccurately("S", size: .letter, scale: 2.0) }
    func testRenderCharLetterT() { assertCharRenderedAccurately("T", size: .letter, scale: 2.0) }
    func testRenderCharLetterU() { assertCharRenderedAccurately("U", size: .letter, scale: 2.0) }
    func testRenderCharLetterV() { assertCharRenderedAccurately("V", size: .letter, scale: 2.0) }
    func testRenderCharLetterW() { assertCharRenderedAccurately("W", size: .letter, scale: 2.0) }
    func testRenderCharLetterX() { assertCharRenderedAccurately("X", size: .letter, scale: 2.0) }
    func testRenderCharLetterY() { assertCharRenderedAccurately("Y", size: .letter, scale: 2.0) }
    func testRenderCharLetterZ() { assertCharRenderedAccurately("Z", size: .letter, scale: 2.0) }

    // MARK: Digits 0-9 (10 characters)
    func testRenderCharDigitZero()  { assertCharRenderedAccurately("0", size: .digit, scale: 2.0) }
    func testRenderCharDigitOne()   { assertCharRenderedAccurately("1", size: .digit, scale: 2.0) }
    func testRenderCharDigitTwo()   { assertCharRenderedAccurately("2", size: .digit, scale: 2.0) }
    func testRenderCharDigitThree() { assertCharRenderedAccurately("3", size: .digit, scale: 2.0) }
    func testRenderCharDigitFour()  { assertCharRenderedAccurately("4", size: .digit, scale: 2.0) }
    func testRenderCharDigitFive()  { assertCharRenderedAccurately("5", size: .digit, scale: 2.0) }
    func testRenderCharDigitSix()   { assertCharRenderedAccurately("6", size: .digit, scale: 2.0) }
    func testRenderCharDigitSeven() { assertCharRenderedAccurately("7", size: .digit, scale: 2.0) }
    func testRenderCharDigitEight() { assertCharRenderedAccurately("8", size: .digit, scale: 2.0) }
    func testRenderCharDigitNine()  { assertCharRenderedAccurately("9", size: .digit, scale: 2.0) }

    // MARK: Symbols (7 characters)
    func testRenderCharSymbolPercent()  { assertCharRenderedAccurately("%", size: .letter, scale: 2.0) }
    func testRenderCharSymbolYen()     { assertCharRenderedAccurately("¥", size: .letter, scale: 2.0) }
    func testRenderCharSymbolDollar()  { assertCharRenderedAccurately("$", size: .letter, scale: 2.0) }
    func testRenderCharSymbolDot()     { assertCharRenderedAccurately(".", size: .letter, scale: 2.0) }
    func testRenderCharSymbolQuestion() { assertCharRenderedAccurately("?", size: .letter, scale: 2.0) }
    func testRenderCharSymbolBullet()  { assertCharRenderedAccurately("\u{2022}", size: .letter, scale: 2.0) }
    func testRenderCharSymbolSlash()   { assertCharRenderedAccurately("/", size: .letter, scale: 2.0) }

    func testRenderCharUnknownDoesNotCrash() {
        // Creating a small context and rendering an unknown char should not throw
        let (context, _) = makeBitmapContext(width: 20, height: 20)
        PixelFontEngine.renderChar("@", size: .letter, at: .zero, color: .white, scale: 2.0, in: context)
        // If we reach here, no crash occurred
        XCTAssertTrue(true)
    }

    // MARK: - Text composition

    func testRenderTextMXWidth() {
        let mWidth = PixelFontEngine.textWidth("M", scale: 2.0)
        let xWidth = PixelFontEngine.textWidth("X", scale: 2.0)
        let gap = PixelFontEngine.charGap

        let combinedWidth = PixelFontEngine.textWidth("MX", scale: 2.0)
        XCTAssertEqual(combinedWidth, mWidth + gap + xWidth, accuracy: 0.001)
    }

    func testRenderTextPercentage() {
        let scale: CGFloat = 2.0
        let (context, pixels) = makeBitmapContext(width: 60, height: 30)
        PixelFontEngine.renderText("82%", at: CGPoint(x: 0, y: 0), color: .white, scale: scale, in: context)

        // "8" and "2" are digits (3×5), "%" is a letter (5×7)
        // Total width = 3*scale + gap + 3*scale + gap + 5*scale
        let expectedWidth = 3 * scale + PixelFontEngine.charGap
                        + 3 * scale + PixelFontEngine.charGap
                        + 5 * scale
        let returnedWidth = PixelFontEngine.renderText("82%", at: .zero, color: .white, scale: scale, in: context)
        XCTAssertEqual(returnedWidth, expectedWidth, accuracy: 0.001)

        // Verify that at least some white pixels were rendered
        let whiteCount = countWhitePixels(in: pixels, width: 60, height: 30)
        XCTAssertGreaterThan(whiteCount, 0, "Text '82%' should render visible pixels")
    }

    func testRenderTextBalance() {
        let scale: CGFloat = 2.0
        let (context, pixels) = makeBitmapContext(width: 60, height: 30)
        PixelFontEngine.renderText("¥45", at: CGPoint(x: 0, y: 0), color: .white, scale: scale, in: context)

        let whiteCount = countWhitePixels(in: pixels, width: 60, height: 30)
        XCTAssertGreaterThan(whiteCount, 0, "Text '¥45' should render visible pixels")
    }

    func testRenderTextEmptyString() {
        let width = PixelFontEngine.textWidth("", scale: 2.0)
        XCTAssertEqual(width, 0, accuracy: 0.001)
    }

    // MARK: - Progress bar

    func testProgressBarZeroFill() {
        let (context, pixels) = makeBitmapContext(width: 20, height: 10)
        PixelFontEngine.renderProgressBar(at: .zero, width: 14, height: 4, percent: 30, color: .white, in: context)

        // 30% <= 50% → no fill inside the outline
        // Outline itself should render some pixels
        let whiteCount = countWhitePixels(in: pixels, width: 20, height: 10)
        XCTAssertGreaterThan(whiteCount, 0, "Progress bar outline should be visible")

        // Inner area should be mostly empty (just outline)
        // For a 14×4 bar, outline is roughly perimeter pixels
        XCTAssertLessThan(whiteCount, 30, "0-50% bar should only show outline, not fill")
    }

    func testProgressBarHalfFill() {
        let (context, pixels) = makeBitmapContext(width: 20, height: 10)
        PixelFontEngine.renderProgressBar(at: .zero, width: 14, height: 4, percent: 70, color: .white, in: context)

        let whiteCount = countWhitePixels(in: pixels, width: 20, height: 10)
        // 50-80% → half fill → more pixels than outline-only
        XCTAssertGreaterThan(whiteCount, 15, "50-80% bar should have partial fill")
    }

    func testProgressBarFullFill() {
        let (context, pixels) = makeBitmapContext(width: 20, height: 10)
        PixelFontEngine.renderProgressBar(at: .zero, width: 14, height: 4, percent: 95, color: .white, in: context)

        let whiteCount = countWhitePixels(in: pixels, width: 20, height: 10)
        // 80-100% → full fill → most of the inner area filled
        XCTAssertGreaterThan(whiteCount, 25, "80-100% bar should have full fill")
    }

    // MARK: - Slot rendering

    func testRenderSlotQuota() {
        let scale: CGFloat = 2.0
        let slot = SlotViewData(
            uuid: "test-quota",
            displayName: "Test",
            shortName: "MX",
            instanceType: .quota(percent: 82, usageValue: "820", limitValue: "1000", nextRefreshMinutes: 3, cycleRemainingDays: 5),
            sortOrder: 0,
            colorState: .normal
        )

        let (context, pixels) = makeBitmapContext(width: 80, height: 30)
        let width = PixelFontEngine.renderSlot(at: .zero, data: slot, color: .white, scale: scale, in: context)

        XCTAssertGreaterThan(width, 0, "Slot should have positive width")
        let whiteCount = countWhitePixels(in: pixels, width: 80, height: 30)
        XCTAssertGreaterThan(whiteCount, 0, "Quota slot should render visible pixels")
    }

    func testRenderSlotBalance() {
        let scale: CGFloat = 2.0
        let slot = SlotViewData(
            uuid: "test-balance",
            displayName: "Test",
            shortName: "DS",
            instanceType: .balance(amount: "45.50", totalBalance: "50.00", grantedBalance: "4.50", isAvailable: true, currency: "CNY"),
            sortOrder: 1,
            colorState: .warning
        )

        let (context, pixels) = makeBitmapContext(width: 80, height: 30)
        let width = PixelFontEngine.renderSlot(at: .zero, data: slot, color: .white, scale: scale, in: context)

        XCTAssertGreaterThan(width, 0, "Slot should have positive width")
        let whiteCount = countWhitePixels(in: pixels, width: 80, height: 30)
        XCTAssertGreaterThan(whiteCount, 0, "Balance slot should render visible pixels")
    }

    // MARK: - Helpers

    /// Creates a bitmap CGContext and returns it along with a mutable data buffer.
    private func makeBitmapContext(width: Int, height: Int) -> (CGContext, UnsafeMutablePointer<UInt8>) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let ptr = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (context, ptr)
    }

    private func countWhitePixels(in ptr: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> Int {
        var count = 0
        for i in 0..<(width * height) {
            let idx = i * 4
            if ptr[idx] > 200 { // R channel
                count += 1
            }
        }
        return count
    }

    /// Renders a single character into a bitmap context and validates that every
    /// expected pixel (from the CharMap) is white and no extra white pixels exist.
    private func assertCharRenderedAccurately(
        _ char: Character,
        size: CharSize,
        scale: CGFloat,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let cols = size.cols
        let rows = size.rows
        let charHeight = CGFloat(rows) * scale
        let baseY = (PixelFontEngine.slotHeight - charHeight) / 2

        let contextWidth = Int(ceil(CGFloat(cols) * scale)) + 4
        let contextHeight = Int(PixelFontEngine.slotHeight) + 4

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: contextWidth,
            height: contextHeight,
            bitsPerComponent: 8,
            bytesPerRow: contextWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("Failed to create CGContext", file: file, line: line)
            return
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: contextWidth, height: contextHeight))

        let color = NSColor(red: 1, green: 1, blue: 1, alpha: 1)
        PixelFontEngine.renderChar(char, size: size, at: CGPoint(x: 2, y: 2), color: color, scale: scale, in: context)

        guard let data = context.data else {
            XCTFail("No context data", file: file, line: line)
            return
        }
        let ptr = data.bindMemory(to: UInt8.self, capacity: contextWidth * contextHeight * 4)

        guard let bitmap = PixelFontEngine.bitmap(for: char, size: size) else {
            XCTFail("No bitmap for character \(char)", file: file, line: line)
            return
        }

        // Verify every expected pixel is white
        for (row, bitmapRow) in bitmap.enumerated() {
            for (col, isLit) in bitmapRow.enumerated() where isLit {
                for dy in 0..<Int(scale) {
                    for dx in 0..<Int(scale) {
                        let x = 2 + col * Int(scale) + dx
                        let drawY = 2 + Int(baseY) + (rows - 1 - row) * Int(scale) + dy
                        let dataY = (contextHeight - 1) - drawY
                        let idx = (dataY * contextWidth + x) * 4
                        XCTAssertGreaterThan(ptr[idx], 200, "Expected white pixel at (\(x),\(drawY)) for '\(char)'", file: file, line: line)
                    }
                }
            }
        }

        // Verify pixel count matches exactly
        var expectedCount = 0
        for row in bitmap {
            for isLit in row where isLit { expectedCount += 1 }
        }
        expectedCount *= Int(scale) * Int(scale)

        var actualCount = 0
        for y in 0..<contextHeight {
            for x in 0..<contextWidth {
                let idx = (y * contextWidth + x) * 4
                if ptr[idx] > 200 { actualCount += 1 }
            }
        }
        XCTAssertEqual(actualCount, expectedCount, "Pixel count mismatch for '\(char)'", file: file, line: line)
    }
}

#endif // false
