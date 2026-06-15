import Foundation

/// Hard-coded upper bounds for the OpenCode Go plan.
///
/// Source: https://opencode.ai/docs/go/ (verified 2026-06-15).
/// When the upstream pricing changes, update these and document the change
/// in `docs/provider-interfaces/opencode_go.md`. Long-term these should
/// become user-configurable in Settings.
enum OpenCodeGoLimits {
    static let fiveHour: Double = 12.0
    static let weekly:   Double = 30.0
    static let monthly:  Double = 60.0
}
