import SwiftUI

// MARK: - EmptyStateView

/// Shown inside the Popover when no service instances are configured.
struct EmptyStateView: View {
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 36))
                .foregroundColor(Color.textSecondary.opacity(0.6))

            Text("No services configured")
                .font(.headline)
                .foregroundColor(Color.textPrimary)

            Text("Add your first service to start tracking API usage.")
                .font(.caption)
                .foregroundColor(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)

            Button("Add First Service") {
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 300, minHeight: 220)
    }
}


