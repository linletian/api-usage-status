import SwiftUI

// MARK: - InstanceCardView

/// A compact card row representing a single instance in the settings sidebar.
///
/// Layout (left → right):
///   StatusDotView → VStack(displayName + subtitle) → shortName badge →
///   tracking Toggle → edit button → delete button
///
/// Metric visibility (displayInMenuBar) is managed through the instance editor,
/// not here — no inline expansion needed.
struct InstanceCardView: View {
    let instance: Instance
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggleTracking: () -> Void

    // MARK: - Body

    var body: some View {
        cardRow
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cardBg)
            )
            .shadow(color: Color.cardShadow.opacity(0.06), radius: 2, x: 0, y: 1)
    }

    private var cardRow: some View {
        HStack(spacing: 10) {
            // 1. Status dot
            StatusDotView(isTracking: instance.trackingEnabled)

            // 2. Name + subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // 3. shortName badge
            Text(instance.shortName)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.cardBorder)
                )

            // 4. Tracking toggle
            Toggle("", isOn: trackingBinding)
            .toggleStyle(.switch)
            .controlSize(.small)

            // 5. Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.borderless)

            // 6. Delete button
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(Color.dangerRed)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    // MARK: - Computed

    // Internal (not private) so `InstanceCardViewTests` can pin these
    // contracts without rendering the view — the XCTest bundle cannot host
    // SwiftUI view hierarchies (see the test file's header).

    var displayName: String {
        instance.displayName.isEmpty ? "Untitled" : instance.displayName
    }

    var subtitle: String {
        "\(providerDisplayName(instance.provider)) · \(instance.dimension)"
    }

    func providerDisplayName(_ raw: String) -> String {
        Provider(rawValue: raw)?.displayName ?? raw.capitalized
    }

    /// Toggle binding for the tracking switch: get mirrors
    /// `instance.trackingEnabled`; any set forwards to `onToggleTracking`
    /// (the actual toggle decision belongs to the view model).
    var trackingBinding: Binding<Bool> {
        Binding(
            get: { instance.trackingEnabled },
            set: { _ in onToggleTracking() }
        )
    }
}