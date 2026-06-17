import SwiftUI

// MARK: - StatusDotView

/// A 10×10 pt circular indicator that reflects the current tracking state.
///
/// - `isTracking == true`  → filled with `Color.trackingOn` (green)
/// - `isTracking == false` → filled with `Color.trackingOff` (gray)
///
/// Used in the usage panel and settings list rows as a compact on/off badge.
struct StatusDotView: View {
    let isTracking: Bool

    var body: some View {
        Circle()
            .fill(isTracking ? Color.trackingOn : Color.trackingOff)
            .frame(width: 10, height: 10)
    }
}
