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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    providerSection
                    metricsSection
                    displaySection
                    apiKeySection

                    if isBalanceType {
                        currencySection
                    }

                    thresholdSection
                }
                .padding(20)
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            bottomBar
        }
        .frame(minWidth: 500, minHeight: 480)
        .onAppear {
            loadExistingData()
        }
        .onChange(of: thresholds) { _ in
            validationError = nil
        }
    }

    // MARK: - Section Views

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PROVIDER")

            Picker(selection: $provider) {
                ForEach(Provider.allCases, id: \.self) { p in
                    HStack(spacing: 8) {
                        Image(systemName: p.sfSymbolName)
                            .frame(width: 16, height: 16)
                        Text(p.displayName)
                    }
                    .tag(p)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: provider.sfSymbolName)
                        .frame(width: 16, height: 16)
                    Text(provider.displayName)
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.textSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.cardBg)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cardBorder, lineWidth: 1)
                )
            }
            .pickerStyle(.menu)
            .onChange(of: provider) { _ in
                resetMetricsForProvider()
                validationError = nil
            }
        }
    }

    // MARK: - Metrics Section

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("METRICS TO TRACK")

            metricsContent
        }
    }

    @ViewBuilder
    private var metricsContent: some View {
        switch provider {
        case .minimax:
            miniMaxMetricsCards
        case .opencode:
            openCodeMetricsList
        case .deepseek, .githubCopilot:
            singleMetricCard
        }
    }

    // MARK: - MiniMax Metrics Cards

    @ViewBuilder
    private var miniMaxMetricsCards: some View {
        if miniMaxModelNames.isEmpty {
            Text("No models detected yet. Add the instance and refresh to discover available models.")
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 8) {
                ForEach(miniMaxModelNames, id: \.self) { modelName in
                    miniMaxModelCard(modelName)
                }
            }
        }
    }

    private func miniMaxModelCard(_ modelName: String) -> some View {
        let isSelected = miniMaxModelIsSelected(modelName)

        return VStack(alignment: .leading, spacing: 0) {
            // Card header: checkbox + model name
            Button {
                toggleMiniMaxModel(modelName)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? .accentBlue : .textSecondary)
                        .font(.system(size: 15))
                    Text(modelName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.textPrimary)
                    Spacer()
                }
                .padding(10)
            }
            .buttonStyle(.plain)

            // Expanded: window toggle rows + short name fields
            if isSelected {
                Divider()
                    .padding(.horizontal, 10)

                VStack(alignment: .leading, spacing: 6) {
                    miniMaxWindowRow(modelName: modelName, window: "5h", label: "5h")
                    miniMaxWindowRow(modelName: modelName, window: "weekly", label: "Weekly")
                }
                .padding(12)
            }
        }
        .background(Color.cardBg)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    private func miniMaxWindowRow(modelName: String, window: String, label: String) -> some View {
        let isOn = miniMaxWindowIsSelected(modelName: modelName, window: window)

        return HStack(spacing: 8) {
            Button {
                toggleMiniMaxWindow(modelName: modelName, window: window)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .foregroundColor(isOn ? .accentBlue : .textSecondary)
                        .font(.system(size: 12))
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundColor(.textPrimary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            metricShortNameField(modelName: modelName, window: window)
                .frame(width: 48)
        }
    }

    // MARK: - OpenCode Metrics

    @ViewBuilder
    private var openCodeMetricsList: some View {
        VStack(spacing: 6) {
            ForEach(openCodeMetricOptions, id: \.key) { metric in
                let window = metric.window ?? ""
                let isSelected = openCodeMetricIsSelected(window)

                HStack(spacing: 8) {
                    Button {
                        toggleOpenCodeMetric(window)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundColor(isSelected ? .accentBlue : .textSecondary)
                                .font(.system(size: 14))
                            Text(openCodeWindowDisplayName(window))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)

                    if isSelected {
                        Spacer()

                        openCodeShortNameField(window: window)
                            .frame(width: 48)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.cardBg)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cardBorder, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Single Metric Card (DeepSeek / Copilot)

    @ViewBuilder
    private var singleMetricCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.square.fill")
                .foregroundColor(.accentBlue)
                .font(.system(size: 14))
            Text(dimensionDisplayName(singleMetricForProvider.key))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.textPrimary)
            Text("— always tracked")
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.cardBg)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Display Section

    @ViewBuilder
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("DISPLAY")

            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text("Display Name")
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .frame(width: 80, alignment: .trailing)
                    TextField("e.g. MiniMax Production", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                HStack(spacing: 12) {
                    Text("Short Name")
                        .font(.system(size: 12))
                        .foregroundColor(.textSecondary)
                        .frame(width: 80, alignment: .trailing)
                    TextField("MX", text: $shortName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 80)
                        .onChange(of: shortName) { _ in
                            shortName = String(shortName.prefix(3)).uppercased()
                            validationError = nil
                        }
                    Text("2-3 uppercase letters/digits")
                        .font(.system(size: 10))
                        .foregroundColor(.textTertiary)
                }
            }
            .padding(12)
            .background(Color.cardBg)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - API Key Section

    @ViewBuilder
    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("API KEY")

            if provider == .opencode {
                Text("Requires the `opencode` CLI to be installed locally and authenticated with OpenCode Go. The supplier reads usage data from the local OpenCode SQLite database — no remote API key is required.")
                    .font(.system(size: 11))
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBg)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.cardBorder, lineWidth: 1)
                    )
            } else {
                SecureInput(text: $apiKey, placeholder: apiKeyPlaceholder)
                    .frame(height: 28)
            }
        }
    }

    // MARK: - Currency Section

    @ViewBuilder
    private var currencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CURRENCY")

            HStack(spacing: 12) {
                Text("Currency")
                    .font(.system(size: 12))
                    .foregroundColor(.textSecondary)
                Picker("", selection: $currency) {
                    Text("CNY (¥)").tag("CNY")
                    Text("USD ($)").tag("USD")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Spacer()
            }
            .padding(12)
            .background(Color.cardBg)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.cardBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Threshold Section

    @ViewBuilder
    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("THRESHOLDS")

            ThresholdConfigView(thresholds: $thresholds)
                .padding(12)
                .background(Color.cardBg)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cardBorder, lineWidth: 1)
                )
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Section Header Helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.textTertiary)
    }

    // MARK: - Metrics State Helpers

    private var openCodeMetricOptions: [MetricConfig] {
        ["5h", "weekly", "monthly"].map { window in
            MetricConfig(key: window, group: nil, window: window, displayInMenuBar: true)
        }
    }

    private var singleMetricForProvider: MetricConfig {
        switch provider {
        case .deepseek:
            return MetricConfig(key: "deepseek.balance", group: nil, window: nil, displayInMenuBar: true)
        case .githubCopilot:
            return MetricConfig(key: "premium_interactions", group: nil, window: nil, displayInMenuBar: true)
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
            selectedMetrics.append(MetricConfig(key: modelName, group: modelName, window: "5h"))
            selectedMetrics.append(MetricConfig(key: "\(modelName):weekly_percent", group: modelName, window: "weekly"))
        } else {
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
            selectedMetrics.append(MetricConfig(key: window, group: nil, window: window))
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
        TextField(window, text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onChange(of: binding.wrappedValue) { newValue in
                let filtered = String(newValue.prefix(3)).uppercased()
                if filtered != newValue {
                    binding.wrappedValue = filtered
                }
            }
    }

    @ViewBuilder
    private func openCodeShortNameField(window: String) -> some View {
        let binding = Binding<String>(
            get: { metricShortName(for: nil, window: window) },
            set: { setMetricShortName(for: nil, window: window, name: $0) }
        )
        TextField(window, text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10, design: .monospaced))
            .onChange(of: binding.wrappedValue) { newValue in
                let filtered = String(newValue.prefix(3)).uppercased()
                if filtered != newValue {
                    binding.wrappedValue = filtered
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
            selectedMetrics = [MetricConfig(key: "premium_interactions", group: nil, window: nil)]
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
            apiKey = ""
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
