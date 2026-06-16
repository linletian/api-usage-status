import XCTest
@testable import APIUsageStatus

final class BreathingMathTests: XCTestCase {

    // MARK: - breathingPhase

    func testPhaseAtZeroReturnsZero() {
        // Given: elapsed time at the very start of a cycle
        let elapsed: TimeInterval = 0
        let config = BreathingConfig.warning

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then
        XCTAssertEqual(phase, 0.0, accuracy: 0.01)
    }

    func testPhaseAtInhaleDurationReturnsNearOne() {
        // Given: elapsed time exactly at the end of the inhale phase
        let config = BreathingConfig.warning
        let elapsed = config.inhaleDuration

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then: t = 1.0, t*t = 1.0
        XCTAssertEqual(phase, 1.0, accuracy: 0.01)
    }

    func testPhaseAtCycleDurationReturnsNearZero() {
        // Given: elapsed time exactly at the end of a full cycle
        let config = BreathingConfig.warning
        let elapsed = config.cycleDuration

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then: exhale phase t=1.0, 1 - t*t = 0
        XCTAssertEqual(phase, 0.0, accuracy: 0.01)
    }

    func testPhasePeriodicAtDoubleCycle() {
        // Given: elapsed time at exactly twice the cycle duration
        let config = BreathingConfig.warning
        let elapsed = config.cycleDuration * 2

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then: should be identical to elapsed=0
        XCTAssertEqual(phase, 0.0, accuracy: 0.01)
    }

    func testPhaseMidInhale() {
        // Given: elapsed time at the midpoint of the inhale phase
        let config = BreathingConfig.warning
        let elapsed = config.inhaleDuration / 2.0

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then: t = 0.5, t*t = 0.25
        XCTAssertEqual(phase, 0.25, accuracy: 0.01)
    }

    func testPhaseMidExhale() {
        // Given: elapsed time at the midpoint of the exhale phase
        let config = BreathingConfig.warning
        let elapsed = config.inhaleDuration + config.exhaleDuration / 2.0

        // When
        let phase = breathingPhase(elapsed: elapsed, config: config)

        // Then: exhale t = 0.5, 1 - t*t = 0.75
        XCTAssertEqual(phase, 0.75, accuracy: 0.01)
    }

    func testPhaseCriticalConfigIsFaster() {
        // Given: both warning and critical configs
        let warningConfig = BreathingConfig.warning
        let criticalConfig = BreathingConfig.critical
        let elapsed: TimeInterval = 2.0

        // When
        let warningPhase = breathingPhase(elapsed: elapsed, config: warningConfig)
        let criticalPhase = breathingPhase(elapsed: elapsed, config: criticalConfig)

        // Then: critical cycles faster (2.0s vs 4.0s), so at t=2.0 it should be at
        // a different phase than warning (which has a 4.0s cycle).
        // At t=2.0, critical has completed exactly 1 cycle → phase ≈ 0.
        // Warning at 2.0s: 0.6s into exhale → t=0.231, phase ≈ 0.947.
        // They should differ.
        XCTAssertNotEqual(warningPhase, criticalPhase, accuracy: 0.01)
    }

    // MARK: - shadowRadius

    func testShadowRadiusAtPhaseZeroReturnsMin() {
        // Given: phase = 0 and warning config
        let config = BreathingConfig.warning

        // When
        let radius = shadowRadius(forPhase: 0.0, config: config)

        // Then
        XCTAssertEqual(radius, config.minShadowBlurRadius, accuracy: 0.01)
    }

    func testShadowRadiusAtPhaseOneReturnsMax() {
        // Given: phase = 1.0 and warning config
        let config = BreathingConfig.warning

        // When
        let radius = shadowRadius(forPhase: 1.0, config: config)

        // Then
        XCTAssertEqual(radius, config.maxShadowBlurRadius, accuracy: 0.01)
    }

    func testShadowRadiusAtPhaseHalfReturnsMidpoint() {
        // Given: phase = 0.5 and warning config (min=0, max=6)
        let config = BreathingConfig.warning

        // When
        let radius = shadowRadius(forPhase: 0.5, config: config)

        // Then: 0 + 0.5 * (6 - 0) = 3.0
        XCTAssertEqual(radius, 3.0, accuracy: 0.01)
    }

    // MARK: - shadowOpacity

    func testShadowOpacityAtPhaseZeroReturnsMin() {
        // Given: phase = 0 and warning config
        let config = BreathingConfig.warning

        // When
        let opacity = shadowOpacity(forPhase: 0.0, config: config)

        // Then
        XCTAssertEqual(opacity, config.minShadowOpacity, accuracy: 0.01)
    }

    func testShadowOpacityAtPhaseOneReturnsMax() {
        // Given: phase = 1.0 and warning config
        let config = BreathingConfig.warning

        // When
        let opacity = shadowOpacity(forPhase: 1.0, config: config)

        // Then
        XCTAssertEqual(opacity, config.maxShadowOpacity, accuracy: 0.01)
    }

    func testShadowOpacityAtPhaseHalfReturnsMidpoint() {
        // Given: phase = 0.5 and warning config (min=0, max=0.7)
        let config = BreathingConfig.warning

        // When
        let opacity = shadowOpacity(forPhase: 0.5, config: config)

        // Then: 0 + 0.5 * (0.7 - 0) = 0.35
        XCTAssertEqual(opacity, 0.35, accuracy: 0.01)
    }

    // MARK: - Config numeric differences

    func testWarningConfigValues() {
        // Given: warning config
        let config = BreathingConfig.warning

        // Then: verify all static values
        XCTAssertEqual(config.cycleDuration, 4.0, accuracy: 0.01)
        XCTAssertEqual(config.inhaleDuration, 1.4, accuracy: 0.01)
        XCTAssertEqual(config.exhaleDuration, 2.6, accuracy: 0.01)
        XCTAssertEqual(config.minShadowBlurRadius, 0, accuracy: 0.01)
        XCTAssertEqual(config.maxShadowBlurRadius, 6, accuracy: 0.01)
        XCTAssertEqual(config.minShadowOpacity, 0, accuracy: 0.01)
        XCTAssertEqual(config.maxShadowOpacity, 0.7, accuracy: 0.01)
    }

    func testCriticalConfigValues() {
        // Given: critical config
        let config = BreathingConfig.critical

        // Then: verify all static values
        XCTAssertEqual(config.cycleDuration, 2.0, accuracy: 0.01)
        XCTAssertEqual(config.inhaleDuration, 0.7, accuracy: 0.01)
        XCTAssertEqual(config.exhaleDuration, 1.3, accuracy: 0.01)
        XCTAssertEqual(config.minShadowBlurRadius, 0, accuracy: 0.01)
        XCTAssertEqual(config.maxShadowBlurRadius, 8, accuracy: 0.01)
        XCTAssertEqual(config.minShadowOpacity, 0, accuracy: 0.01)
        XCTAssertEqual(config.maxShadowOpacity, 0.85, accuracy: 0.01)
    }

    func testCriticalConfigHasShorterCycleThanWarning() {
        // Then: critical cycle should be shorter (more urgent breathing)
        XCTAssertLessThan(BreathingConfig.critical.cycleDuration, BreathingConfig.warning.cycleDuration)
        XCTAssertGreaterThan(BreathingConfig.critical.maxShadowBlurRadius, BreathingConfig.warning.maxShadowBlurRadius)
        XCTAssertGreaterThan(BreathingConfig.critical.maxShadowOpacity, BreathingConfig.warning.maxShadowOpacity)
    }

    func testInhaleAndExhaleSumToCycle() {
        // Given: both configs

        // Then
        let warningSum = BreathingConfig.warning.inhaleDuration + BreathingConfig.warning.exhaleDuration
        XCTAssertEqual(warningSum, BreathingConfig.warning.cycleDuration, accuracy: 0.01)

        let criticalSum = BreathingConfig.critical.inhaleDuration + BreathingConfig.critical.exhaleDuration
        XCTAssertEqual(criticalSum, BreathingConfig.critical.cycleDuration, accuracy: 0.01)
    }
}
