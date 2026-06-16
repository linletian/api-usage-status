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
    @State private var selectedMetrics: [MetricConfig] = []
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
                    Picker("Provider", selection: Binding<Provider>(
                        get: { provider },
                        set: { newProvider in
                            provider = newProvider
                            resetMetricsForProvider()
                            validationError = nil
                        }
                    )) {
                        ForEach(Provider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }

                    metricsEditorSection

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
        .onChange(of: thresholds) { _ in
            validationError = nil
        }
    }

    // MARK: - Metrics Editor

    @ViewBuilder
    private var metricsEditorSection: some View {
        switch provider {
        case .minimax:
            miniMaxMetricsEditor
        case .opencode:
            openCodeMetricsEditor
        case .deepseek, .githubCopilot:
            singleMetricLabel
        }
    }

    @ViewBuilder
    private var miniMaxMetricsEditor: some View {
        if miniMaxModelNames.isEmpty {
            Text("No models detected yet. Add the instance and refresh to discover available models.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        } else {
            ForEach(miniMaxModelNames, id: \.self) { modelName in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: miniMaxModelIsSelected(modelName) ? "checkmark.square" : "square")
                            .foregroundColor(miniMaxModelIsSelected(modelName) ? .accentColor : .secondary)
                        Text(modelName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { toggleMiniMaxModel(modelName) }

                    if miniMaxModelIsSelected(modelName) {
                        HStack(spacing: 16) {
                            metricWindowToggle(modelName: modelName, window: "5h")
                            metricWindowToggle(modelName: modelName, window: "weekly")
                        }
                        .padding(.leading, 24)

                        HStack(spacing: 10) {
                            metricShortNameField(modelName: modelName, window: "5h")
                            metricShortNameField(modelName: modelName, window: "weekly")
                        }
                        .padding(.leading, 24)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var openCodeMetricsEditor: some View {
        ForEach(openCodeMetricOptions, id: \.key) { metric in
            HStack {
                Image(systemName: openCodeMetricIsSelected(metric.window ?? "") ? "checkmark.square" : "square")
                    .foregroundColor(openCodeMetricIsSelected(metric.window ?? "") ? .accentColor : .secondary)
                Text(openCodeWindowDisplayName(metric.window ?? ""))
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleOpenCodeMetric(metric.window ?? "") }

            if openCodeMetricIsSelected(metric.window ?? "") {
                openCodeShortNameField(window: metric.window ?? "")
                    .padding(.leading, 24)
            }
        }
    }

    private var singleMetricLabel: some View {
        Text("\(dimensionDisplayName(singleMetricForProvider.key)) — always tracked")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func metricWindowToggle(modelName: String, window: String) -> some View {
        let isSelected = miniMaxWindowIsSelected(modelName: modelName, window: window)
        HStack(spacing: 4) {
            Image(systemName: isSelected ? "checkmark.square" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.system(size: 11))
            Text(window)
                .font(.system(size: 11))
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleMiniMaxWindow(modelName: modelName, window: window) }
    }

    // MARK: - Metrics State Helpers

    private var openCodeMetricOptions: [MetricConfig] {
        ["5h", "weekly", "monthly"].map { window in
            MetricConfig(key: "opencode.\(window)", group: nil, window: window, displayInMenuBar: true)
        }
    }

    private var singleMetricForProvider: MetricConfig {
        switch provider {
        case .deepseek:
            return MetricConfig(key: "deepseek.balance", group: nil, window: nil, displayInMenuBar: true)
        case .githubCopilot:
            return MetricConfig(key: "githubCopilot.premium_interactions", group: nil, window: nil, displayInMenuBar: true)
        default:
            return MetricConfig(key: "", displayInMenuBar: true)
        }
    }

    private func miniMaxModelIsSelected(_ modelName: String) -> Bool {
        selectedMetrics.contains { $0.group == modelName && $0.displayInMenuBar }
    }

    private func miniMaxWindowIsSelected(modelName: String, window: String) -> Bool {
        selectedMetrics.contains { $0.group == modelName && $0.window == window && $0.displayInMenuBar }
    }

    private func toggleMiniMaxModel(_ modelName: String) {
        let modelMetrics = selectedMetrics.filter { $0.group == modelName }
        if modelMetrics.isEmpty {
            // Add both 5h and weekly by default.
            // Keys must match rawData from MiniMaxResponseParser:
            //   5h    → rawData["<modelName>"] (usage percent)
            //   weekly → rawData["<modelName>:weekly_percent"]
            selectedMetrics.append(MetricConfig(key: modelName, group: modelName, window: "5h"))
            selectedMetrics.append(MetricConfig(key: "\(modelName):weekly_percent", group: modelName, window: "weekly"))
        } else {
            // Toggle enabled state instead of removing.
            // Keeping the metrics in the array prevents auto-discovery
            // from re-adding them on the next refresh.
            let newState = !modelMetrics.contains { $0.displayInMenuBar }
            for idx in selectedMetrics.indices where selectedMetrics[idx].group == modelName {
                selectedMetrics[idx].displayInMenuBar = newState
            }
        }
    }

    private func toggleMiniMaxWindow(modelName: String, window: String) {
        let key: String
        switch window {
        case "5h":   key = modelName
        case "weekly": key = "\(modelName):weekly_percent"
        default:     key = "\(modelName):\(window)"
        }
        if let idx = selectedMetrics.firstIndex(where: { $0.group == modelName && $0.window == window }) {
            selectedMetrics[idx].displayInMenuBar.toggle()
        } else {
            selectedMetrics.append(MetricConfig(key: key, group: modelName, window: window))
        }
    }

    private func openCodeMetricIsSelected(_ window: String) -> Bool {
        selectedMetrics.contains { $0.window == window }
    }

    private func toggleOpenCodeMetric(_ window: String) {
        if let idx = selectedMetrics.firstIndex(where: { $0.window == window }) {
            selectedMetrics.remove(at: idx)
        } else {
            selectedMetrics.append(MetricConfig(key: "opencode.\(window)", group: nil, window: window))
        }
    }

    private func openCodeWindowDisplayName(_ window: String) -> String {
        switch window {
        case "5h": return "5-Hour Window"
        case "weekly": return "Weekly Window"
        case "monthly": return "Monthly Window"
        default: return window
        }
    }

    // MARK: - Metric Short Name Fields

    @ViewBuilder
    private func metricShortNameField(modelName: String, window: String) -> some View {
        let binding = Binding<String>(
            get: { metricShortName(for: modelName, window: window) },
            set: { setMetricShortName(for: modelName, window: window, name: $0) }
        )
        HStack(spacing: 4) {
            Text("Name")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            TextField(window, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 36)
                .onChange(of: binding.wrappedValue) { newValue in
                    let filtered = String(newValue.prefix(3)).uppercased()
                    if filtered != newValue {
                        binding.wrappedValue = filtered
                    }
                }
        }
    }

    @ViewBuilder
    private func openCodeShortNameField(window: String) -> some View {
        let binding = Binding<String>(
            get: { metricShortName(for: nil, window: window) },
            set: { setMetricShortName(for: nil, window: window, name: $0) }
        )
        HStack(spacing: 4) {
            Text("Name")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            TextField(window, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 36)
                .onChange(of: binding.wrappedValue) { newValue in
                    let filtered = String(newValue.prefix(3)).uppercased()
                    if filtered != newValue {
                        binding.wrappedValue = filtered
                    }
                }
        }
    }

    private func metricShortName(for group: String?, window: String) -> String {
        selectedMetrics.first(where: {
            ($0.group == group || (group == nil && $0.group == nil))
            && $0.window == window
        })?.shortName ?? ""
    }

    private func setMetricShortName(for group: String?, window: String, name: String) {
        let cleaned = String(name.prefix(3)).uppercased()
        if let idx = selectedMetrics.firstIndex(where: {
            ($0.group == group || (group == nil && $0.group == nil))
            && $0.window == window
        }) {
            selectedMetrics[idx].shortName = cleaned.isEmpty ? nil : cleaned
        }
    }

    // MARK: - Other Helpers

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
        let hasValidShortName = !shortName.isEmpty && shortName.count >= 2 && shortName.count <= 3

        // First-time MiniMax instance: model names aren't discovered yet
        // (no instance exists → no refresh has run → AppState.miniMaxModelNames is empty).
        // Allow adding the instance without metrics so a refresh can discover them;
        // the user can then re-edit to select specific capability buckets.
        if provider == .minimax && miniMaxModelNames.isEmpty && !isEditing {
            return hasValidShortName
        }

        return hasValidShortName && !selectedMetrics.isEmpty
    }

    private func dimensionDisplayName(_ key: String) -> String {
        switch key {
        case "deepseek.balance":
            return "Account Balance"
        case "githubCopilot.premium_interactions":
            return "Premium Interactions"
        default:
            return key
        }
    }

    private func resetMetricsForProvider() {
        switch provider {
        case .minimax:
            selectedMetrics = []
        case .opencode:
            selectedMetrics = openCodeMetricOptions
        case .deepseek:
            selectedMetrics = [MetricConfig(key: "deepseek.balance", group: nil, window: nil)]
        case .githubCopilot:
            selectedMetrics = [MetricConfig(key: "githubCopilot.premium_interactions", group: nil, window: nil)]
        }
        thresholds = isBalanceType ? .defaultBalance : .defaultQuota
    }

    private func loadExistingData() {
        if let instance = existingInstance {
            provider = Provider(rawValue: instance.provider) ?? .minimax
            selectedMetrics = instance.metrics.filter { !$0.key.isEmpty }
            displayName = instance.displayName
            shortName = instance.shortName
            currency = instance.currency ?? "CNY"
            thresholds = instance.thresholds
            apiKey = "" // User must re-enter to change
        } else {
            resetMetricsForProvider()
        }
    }

    private func makeInstance() -> Instance {
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
            dimension: "",
            metrics: selectedMetrics,
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
