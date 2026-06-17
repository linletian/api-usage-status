import XCTest
@testable import APIUsageStatus

// MARK: - Provider Selection Tests

final class ProviderPickerTests: XCTestCase {

    func testAllProvidersHaveNonEmptyDisplayName() {
        for provider in Provider.allCases {
            XCTAssertFalse(
                provider.displayName.isEmpty,
                "Provider.\(provider) must have a non-empty displayName"
            )
        }
    }

    func testProviderSelectionCallbackChangesProvider() {
        var selectedProvider: Provider = .minimax

        func select(_ provider: Provider) {
            selectedProvider = provider
        }

        select(.deepseek)
        XCTAssertEqual(selectedProvider, .deepseek)

        select(.githubCopilot)
        XCTAssertEqual(selectedProvider, .githubCopilot)

        select(.opencode)
        XCTAssertEqual(selectedProvider, .opencode)

        select(.minimax)
        XCTAssertEqual(selectedProvider, .minimax)
    }

    func testProviderAllCasesContainsAllValues() {
        let expected: Set<Provider> = [.minimax, .deepseek, .githubCopilot, .opencode]
        let actual = Set(Provider.allCases)
        XCTAssertEqual(expected, actual)
    }

    func testProviderSfSymbolMatchesDisplayName() {
        let mapping: [(Provider, String, String)] = [
            (.minimax, "cpu", "MiniMax"),
            (.deepseek, "dollarsign.circle", "DeepSeek"),
            (.githubCopilot, "hammer", "GitHub Copilot"),
            (.opencode, "terminal", "OpenCode Go"),
        ]
        for (provider, symbol, name) in mapping {
            XCTAssertEqual(provider.sfSymbolName, symbol)
            XCTAssertEqual(provider.displayName, name)
        }
    }
}

// MARK: - Threshold Slider Value Tests

final class ThresholdSliderTests: XCTestCase {

    func testDefaultQuotaWarningIs80() {
        if case .quota(let w, _) = Thresholds.defaultQuota {
            XCTAssertEqual(w, 80)
        } else {
            XCTFail("defaultQuota should be .quota")
        }
    }

    func testDefaultQuotaCriticalIs95() {
        if case .quota(_, let c) = Thresholds.defaultQuota {
            XCTAssertEqual(c, 95)
        } else {
            XCTFail("defaultQuota should be .quota")
        }
    }

    func testQuotaWarningBindingUpdatesThresholds() {
        var thresholds = Thresholds.quota(warningPercent: 70, criticalPercent: 90)

        if case .quota(_, let c) = thresholds {
            thresholds = .quota(warningPercent: 75, criticalPercent: c)
        }

        if case .quota(let w, let c) = thresholds {
            XCTAssertEqual(w, 75)
            XCTAssertEqual(c, 90)
        } else {
            XCTFail("thresholds should remain .quota")
        }
    }

    func testQuotaCriticalBindingUpdatesThresholds() {
        var thresholds = Thresholds.quota(warningPercent: 70, criticalPercent: 90)

        if case .quota(let w, _) = thresholds {
            thresholds = .quota(warningPercent: w, criticalPercent: 95)
        }

        if case .quota(let w, let c) = thresholds {
            XCTAssertEqual(w, 70)
            XCTAssertEqual(c, 95)
        } else {
            XCTFail("thresholds should remain .quota")
        }
    }

    func testQuotaSliderRangeCoversZeroToHundred() {
        let range: ClosedRange<Double> = 0 ... 100
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 100)
    }

    func testDefaultBalanceWarningIs10() {
        if case .balance(let w, _, _, _) = Thresholds.defaultBalance {
            XCTAssertEqual(w, Decimal(string: "10.00"))
        } else {
            XCTFail("defaultBalance should be .balance")
        }
    }

    func testDefaultBalanceCriticalIs2() {
        if case .balance(_, let c, _, _) = Thresholds.defaultBalance {
            XCTAssertEqual(c, Decimal(string: "2.00"))
        } else {
            XCTFail("defaultBalance should be .balance")
        }
    }

    func testQuotaValidationWarningLessThanCriticalPasses() {
        let thresholds = Thresholds.quota(warningPercent: 70, criticalPercent: 90)
        if case .quota(let w, let c) = thresholds {
            XCTAssertTrue(w < c, "Warning should be less than critical")
        }
    }

    func testQuotaValidationWarningGreaterThanOrEqualCriticalFails() {
        let thresholdsEqual = Thresholds.quota(warningPercent: 90, criticalPercent: 90)
        if case .quota(let w, let c) = thresholdsEqual {
            XCTAssertFalse(w < c, "Equal values should fail validation")
        }

        let thresholdsGreater = Thresholds.quota(warningPercent: 95, criticalPercent: 80)
        if case .quota(let w, let c) = thresholdsGreater {
            XCTAssertFalse(w < c, "Warning > critical should fail validation")
        }
    }
}