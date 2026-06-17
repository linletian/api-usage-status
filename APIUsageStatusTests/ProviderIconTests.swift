import XCTest
@testable import APIUsageStatus

/// Tests for `Provider.sfSymbolName`.
///
/// Verifies the SF Symbol mapping used by the menu bar and settings UI to
/// visually distinguish providers. The mapping is intentionally minimal —
/// one canonical symbol per provider — so a regression here would change
/// every UI surface that renders a provider icon.
final class ProviderIconTests: XCTestCase {

    // MARK: - Coverage

    /// Every case of `Provider` must return a non-empty symbol name.
    /// A `nil`/empty symbol would crash SwiftUI's `Image(systemName:)` at
    /// runtime, so this acts as an exhaustiveness guard.
    func testAllProvidersHaveNonEmptySymbolName() {
        for provider in Provider.allCases {
            XCTAssertFalse(
                provider.sfSymbolName.isEmpty,
                "Provider.\(provider) must have a non-empty sfSymbolName"
            )
        }
    }

    // MARK: - Mapping correctness

    /// Each provider maps to its expected SF Symbol. This is the contract
    /// the UI relies on; changing it would silently rebrand the app.
    func testSymbolMappingMatchesExpectedValues() {
        XCTAssertEqual(Provider.minimax.sfSymbolName, "cpu")
        XCTAssertEqual(Provider.deepseek.sfSymbolName, "dollarsign.circle")
        XCTAssertEqual(Provider.githubCopilot.sfSymbolName, "hammer")
        XCTAssertEqual(Provider.opencode.sfSymbolName, "terminal")
    }

    // MARK: - Hygiene

    /// SF Symbol names must not contain surrounding whitespace. SwiftUI's
    /// `Image(systemName: " cpu ")` will fail to resolve the symbol, so
    /// accidental trimming regressions would render as missing icons.
    func testSymbolNamesContainNoWhitespace() {
        for provider in Provider.allCases {
            let name = provider.sfSymbolName
            XCTAssertEqual(
                name,
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                "Provider.\(provider) sfSymbolName must not contain whitespace"
            )
        }
    }
}
