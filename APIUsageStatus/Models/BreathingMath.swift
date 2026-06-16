import Foundation

// MARK: - BreathingConfig

struct BreathingConfig {
    let cycleDuration: TimeInterval
    let inhaleDuration: TimeInterval
    let exhaleDuration: TimeInterval
    let minShadowBlurRadius: CGFloat
    let maxShadowBlurRadius: CGFloat
    let minShadowOpacity: CGFloat
    let maxShadowOpacity: CGFloat

    static let warning = BreathingConfig(
        cycleDuration: 4.0,
        inhaleDuration: 1.4,
        exhaleDuration: 2.6,
        minShadowBlurRadius: 0,
        maxShadowBlurRadius: 6,
        minShadowOpacity: 0,
        maxShadowOpacity: 0.7
    )

    static let critical = BreathingConfig(
        cycleDuration: 2.0,
        inhaleDuration: 0.7,
        exhaleDuration: 1.3,
        minShadowBlurRadius: 0,
        maxShadowBlurRadius: 8,
        minShadowOpacity: 0,
        maxShadowOpacity: 0.85
    )
}

// MARK: - Pure Functions

/// Returns a normalized 0→1→0 phase value for a breathing animation at the
/// given elapsed time, using segmented easing within the inhale and exhale
/// portions of the breathing cycle.
///
/// - During inhale (0 ≤ position < inhaleDuration): the phase ramps from 0 to
///   1 with an ease-out shape using `t * t`.
/// - During exhale (inhaleDuration ≤ position < cycleDuration): the phase
///   ramps from 1 back to 0 with an ease-in shape using `1 - t * t`.
/// - If `elapsed` exceeds `cycleDuration`, the value wraps via modulo.
///
/// - Parameters:
///   - elapsed: The time interval since the breathing animation started.
///   - config: The breathing configuration determining cycle and phase durations.
/// - Returns: A Double in `[0, 1]` representing the current breathing intensity.
func breathingPhase(elapsed: TimeInterval, config: BreathingConfig) -> Double {
    let position = elapsed.truncatingRemainder(dividingBy: config.cycleDuration)

    if position < config.inhaleDuration {
        // Inhale phase — ease-out: ramps 0 → 1
        let t = position / config.inhaleDuration
        return t * t
    } else {
        // Exhale phase — ease-in: ramps 1 → 0
        let t = (position - config.inhaleDuration) / config.exhaleDuration
        return 1.0 - t * t
    }
}

/// Linearly interpolates the shadow blur radius between the configured minimum
/// and maximum based on the current breathing phase.
///
/// - Parameters:
///   - phase: The normalized breathing intensity in `[0, 1]`.
///   - config: The breathing configuration defining the radius bounds.
/// - Returns: A CGFloat representing the interpolated shadow blur radius.
func shadowRadius(forPhase phase: Double, config: BreathingConfig) -> CGFloat {
    return config.minShadowBlurRadius + CGFloat(phase) * (config.maxShadowBlurRadius - config.minShadowBlurRadius)
}

/// Linearly interpolates the shadow opacity between the configured minimum
/// and maximum based on the current breathing phase.
///
/// - Parameters:
///   - phase: The normalized breathing intensity in `[0, 1]`.
///   - config: The breathing configuration defining the opacity bounds.
/// - Returns: A CGFloat representing the interpolated shadow opacity.
func shadowOpacity(forPhase phase: Double, config: BreathingConfig) -> CGFloat {
    return config.minShadowOpacity + CGFloat(phase) * (config.maxShadowOpacity - config.minShadowOpacity)
}
