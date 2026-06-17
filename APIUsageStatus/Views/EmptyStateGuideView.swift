import SwiftUI

// MARK: - EmptyStateGuideView

/// Centered empty-state guide shown when the user has not yet configured any
/// API instances. Combines a hero icon, a clear title, supporting copy, and a
/// single call-to-action that drives the user toward adding their first
/// instance via the supplied `onAddInstance` closure.
struct EmptyStateGuideView: View {
    /// Invoked when the user taps the primary CTA button. The host is
    /// expected to navigate the user toward the instance creation flow
    /// (typically by opening the Settings window).
    let onAddInstance: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentBlue)

            Text("No Instances Configured")
                .font(.title3)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)

            Text("Add your first API instance to start monitoring usage")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button("Add Your First Instance", action: onAddInstance)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentBlue)
                .controlSize(.regular)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
