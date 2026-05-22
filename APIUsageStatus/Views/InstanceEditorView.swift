import SwiftUI
import AppKit

// MARK: - SecureInput

struct SecureInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSecureTextField {
        let textField = NSSecureTextField()
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.focusRingType = .default
        return textField
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                text = textField.stringValue
            }
        }
    }
}

// MARK: - InstanceEditorView

struct InstanceEditorView: View {
    let existingInstance: Instance?
    let onSave: (Instance, String) -> Void
    let onCancel: () -> Void

    @State private var provider: Provider = .minimax
    @State private var dimension: String = ""
    @State private var displayName: String = ""
    @State private var shortName: String = ""
    @State private var apiKey: String = ""
    @State private var currency: String = "CNY"
    @State private var thresholds: Thresholds = .defaultQuota
    @State private var validationError: String?

    private var isEditing: Bool { existingInstance != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Basic Info") {
                    Picker("Provider", selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }

                    Picker("Dimension", selection: $dimension) {
                        ForEach(availableDimensions, id: \.self) { dim in
                            Text(dimensionDisplayName(dim)).tag(dim)
                        }
                    }

                    TextField("Display Name", text: $displayName)

                    TextField("Short Name (2 uppercase letters, e.g. MX)", text: $shortName)
                        .onChange(of: shortName) { _ in
                            shortName = String(shortName.prefix(2)).uppercased()
                            validationError = nil
                        }

                    SecureInput(text: $apiKey, placeholder: "API Key")

                    if isBalanceType {
                        Picker("Currency", selection: $currency) {
                            Text("CNY (¥)").tag("CNY")
                            Text("USD ($)").tag("USD")
                        }
                    }
                }

                Section("Thresholds") {
                    ThresholdConfigView(thresholds: $thresholds)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 450)

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onCancel()
                }

                Spacer()

                Button(isEditing ? "Save Changes" : "Add Instance") {
                    if validate() {
                        let instance = makeInstance()
                        onSave(instance, apiKey)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormFilled)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 450)
        .onAppear {
            loadExistingData()
        }
        .onChange(of: provider) { _ in
            updateDimensionsForProvider()
            validationError = nil
        }
        .onChange(of: thresholds) { _ in
            validationError = nil
        }
    }

    // MARK: - Helpers

    private var availableDimensions: [String] {
        switch provider {
        case .minimax:
            return ["text_model_5h", "non_text_daily", "weekly_total"]
        case .deepseek:
            return ["balance"]
        }
    }

    private var isBalanceType: Bool {
        provider == .deepseek
    }

    private var isFormFilled: Bool {
        !shortName.isEmpty && shortName.count == 2
    }

    private func dimensionDisplayName(_ dim: String) -> String {
        switch dim {
        case "text_model_5h":
            return "Text Model (5h rolling)"
        case "non_text_daily":
            return "Non-Text (Daily)"
        case "weekly_total":
            return "Weekly Total"
        case "balance":
            return "Account Balance"
        default:
            return dim
        }
    }

    private func updateDimensionsForProvider() {
        dimension = availableDimensions.first ?? ""
        thresholds = isBalanceType ? .defaultBalance : .defaultQuota
    }

    private func loadExistingData() {
        if let instance = existingInstance {
            provider = Provider(rawValue: instance.provider) ?? .minimax
            dimension = instance.dimension
            displayName = instance.displayName
            shortName = instance.shortName
            currency = instance.currency ?? "CNY"
            thresholds = instance.thresholds
            apiKey = "" // User must re-enter to change
        } else {
            updateDimensionsForProvider()
        }
    }

    private func makeInstance() -> Instance {
        Instance(
            uuid: existingInstance?.uuid ?? UUID().uuidString,
            provider: provider.rawValue,
            dimension: dimension,
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: existingInstance?.apiKeyRef ?? UUID().uuidString,
            enabled: existingInstance?.enabled ?? true,
            sortOrder: existingInstance?.sortOrder ?? 0,
            currency: isBalanceType ? currency : nil,
            thresholds: thresholds
        )
    }

    private func validate() -> Bool {
        guard shortName.isValidShortName else {
            validationError = "Short name must be exactly 2 uppercase letters (e.g. MX)"
            return false
        }

        switch thresholds {
        case .quota(let w, let c):
            if w >= c {
                validationError = "Warning threshold must be less than critical threshold"
                return false
            }
        case .balance(let w, let c, _, _):
            if w <= c {
                validationError = "Warning threshold must be greater than critical threshold"
                return false
            }
        }

        validationError = nil
        return true
    }
}
