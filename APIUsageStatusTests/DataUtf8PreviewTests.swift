import XCTest
@testable import APIUsageStatus

final class DataUtf8PreviewTests: XCTestCase {

    func testASCIIWithinLimitsReturnsFullString() {
        let data = Data("hello".utf8)
        XCTAssertEqual(data.utf8Preview(), "hello")
    }

    func testTruncatesByCharacterNotByte() {
        // 600 Chinese characters = 1800 bytes: within the 4 KB byte window,
        // so the 512-character cap is what truncates.
        let text = String(repeating: "配", count: 600)
        let preview = Data(text.utf8).utf8Preview()
        XCTAssertEqual(preview.count, 512)
        XCTAssertEqual(preview, String(repeating: "配", count: 512))
    }

    func testByteWindowSlicingMultiByteSequenceYieldsFallback() {
        // "配" is 3 bytes in UTF-8; a 1-byte window slices through the
        // sequence, so strict decoding must fail and produce the fallback
        // rather than a garbled string. The fallback reports the ORIGINAL
        // byte count, not the window size.
        let data = Data("配额".utf8)  // 6 bytes
        XCTAssertEqual(
            data.utf8Preview(maxBytes: 1),
            "<undecodable UTF-8, 6 bytes>"
        )
    }

    func testByteWindowOnCharacterBoundaryDecodes() {
        let data = Data("配额".utf8)  // 6 bytes, two 3-byte characters
        XCTAssertEqual(data.utf8Preview(maxBytes: 3), "配")
    }

    func testInvalidUTF8YieldsFallback() {
        let data = Data([0xFF, 0xFE, 0x00, 0x01])
        XCTAssertEqual(data.utf8Preview(), "<undecodable UTF-8, 4 bytes>")
    }

    func testEmptyDataReturnsEmptyString() {
        XCTAssertEqual(Data().utf8Preview(), "")
    }
}
