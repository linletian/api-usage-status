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
    let miniMaxModelNames: [String]
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
                        if provider == .minimax {
                            ForEach(miniMaxDimensionOptions, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        } else {
                            ForEach(availableDimensions, id: \.self) { dim in
                                Text(dimensionDisplayName(dim)).tag(dim)
                            }
                        }
                    }

                    TextField("Display Name", text: $displayName)

                    TextField("Short Name (2-3 uppercase letters/digits, e.g. MX or OC5)", text: $shortName)
                        .onChange(of: shortName) { _ in
                            shortName = String(shortName.prefix(3)).uppercased()
                            validationError = nil
                        }

                    if provider == .opencode {
                        // OpenCode Go reads from a local SQLite database via the `opencode` CLI,
                        // so no API key is required. Show an explanatory note in place of
                        // the SecureInput field to make the no-key behavior discoverable.
                        Text("Requires the `opencode` CLI to be installed locally and authenticated with OpenCode Go. The supplier reads usage data from the local OpenCode SQLite database — no remote API key is required.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        SecureInput(text: $apiKey, placeholder: apiKeyPlaceholder)
                    }

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

    private var miniMaxDimensionOptions: [String] {
        var options = miniMaxModelNames
        if !dimension.isEmpty && !options.contains(dimension) {
            options.append(dimension)
        }
        if options.isEmpty {
            options.append("MiniMax-M2.7")
        }
        return options
    }

    private var availableDimensions: [String] {
        switch provider {
        case .deepseek:
            return ["balance"]
        case .githubCopilot:
            return ["premium_interactions"]
        case .opencode:
            return ["5h", "weekly", "monthly"]
        case .minimax:
            return []
        }
    }

    private var isBalanceType: Bool {
        provider == .deepseek
    }

    private var apiKeyPlaceholder: String {
        switch provider {
        case .githubCopilot: return "GitHub PAT (classic, needs copilot scope)"
        case .deepseek, .minimax: return "API Key"
        case .opencode: return "(no API key — uses local opencode CLI)"
        }
    }

    private var isFormFilled: Bool {
        !shortName.isEmpty && shortName.count >= 2 && shortName.count <= 3
    }

    private func dimensionDisplayName(_ dim: String) -> String {
        switch dim {
        case "balance":
            return "Account Balance"
        case "premium_interactions":
            return "Premium Interactions"
        default:
            return dim
        }
    }

    private func updateDimensionsForProvider() {
        if provider == .minimax {
            dimension = miniMaxDimensionOptions.first ?? ""
        } else {
            dimension = availableDimensions.first ?? ""
        }
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
        // OpenCode instances share one fixed apiKeyRef (the placeholder
        // stored in KeychainService). Three separate Instances (5h / weekly
        // / monthly) point to the same ref so RefreshService de-dupes
        // their fetch into a single CLI call.
        let apiKeyRef: String
        if let existing = existingInstance {
            apiKeyRef = existing.apiKeyRef
        } else if provider == .opencode {
            apiKeyRef = KeychainService.openCodePlaceholderRef
        } else {
            apiKeyRef = UUID().uuidString
        }

        return Instance(
            uuid: existingInstance?.uuid ?? UUID().uuidString,
            provider: provider.rawValue,
            dimension: dimension,
            displayName: displayName,
            shortName: shortName,
            apiKeyRef: apiKeyRef,
            enabled: existingInstance?.enabled ?? true,
            sortOrder: existingInstance?.sortOrder ?? 0,
            currency: isBalanceType ? currency : nil,
            thresholds: thresholds
        )
    }

    private func validate() -> Bool {
        guard shortName.isValidShortName else {
            validationError = "Short name must be 2 or 3 uppercase letters or digits (e.g. MX or OC5)"
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
