import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                servicesTab
                    .tabItem {
                        Label("Services", systemImage: "server.rack")
                    }

                generalTab
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }
            }
            .padding(.top, 8)

            Divider()

            HStack {
                if viewModel.isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let error = viewModel.saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 300, alignment: .trailing)
                }

                Button("Save Changes") {
                    Task {
                        _ = await viewModel.save()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSaving)
            }
            .padding()
        }
        .frame(minWidth: 550, minHeight: 400)
        .sheet(isPresented: $viewModel.isPresentingEditor) {
            InstanceEditorView(
                existingInstance: viewModel.editingInstance,
                miniMaxModelNames: viewModel.miniMaxModelNames,
                onSave: { instance, apiKey in
                    if viewModel.editingInstance == nil {
                        viewModel.addInstance(instance, apiKey: apiKey)
                    } else {
                        viewModel.updateInstance(instance, apiKey: apiKey.isEmpty ? nil : apiKey)
                    }
                    viewModel.isPresentingEditor = false
                },
                onCancel: {
                    viewModel.isPresentingEditor = false
                }
            )
            .frame(minWidth: 520, minHeight: 480)
        }
        .confirmationDialog(
            "Delete Instance?",
            isPresented: $viewModel.isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let instance = viewModel.instanceToDelete {
                    Task {
                        await viewModel.deleteInstance(instance)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. The instance configuration and history will be removed.")
        }
    }

    // MARK: - Services Tab

    private var servicesTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.instances) { instance in
                        instanceRow(instance)
                            .contentShape(Rectangle())
                            .onDrag {
                                NSItemProvider(object: instance.uuid as NSString)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button {
                    viewModel.editingInstance = nil
                    viewModel.isPresentingEditor = true
                } label: {
                    Label("Add Instance", systemImage: "plus")
                }
                .padding()
            }
        }
    }

    private func instanceRow(_ instance: Instance) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { instance.enabled },
                set: { viewModel.setInstanceEnabled(uuid: instance.uuid, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName.isEmpty ? "Untitled" : instance.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(providerDisplayName(instance.provider)) · \(instance.dimension)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Text(instance.shortName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 24)

                Button {
                    viewModel.editingInstance = instance
                    viewModel.isPresentingEditor = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)

                Button {
                    viewModel.requestDelete(instance)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerDisplayName(_ raw: String) -> String {
        Provider(rawValue: raw)?.displayName ?? raw.capitalized
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                HStack {
                    Text("Refresh interval")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { viewModel.settings.refreshIntervalMinutes },
                            set: { viewModel.settings.refreshIntervalMinutes = $0 }
                        ),
                        in: 1 ... 60
                    ) {
                        Text("\(viewModel.settings.refreshIntervalMinutes) minute\(viewModel.settings.refreshIntervalMinutes == 1 ? "" : "s")")
                            .monospacedDigit()
                    }
                }
            }

            Section("Appearance") {
                Picker("Color mode", selection: Binding(
                    get: { viewModel.settings.colorMode },
                    set: { viewModel.settings.colorMode = $0 }
                )) {
                    Text("Monochrome").tag(ColorMode.monochrome)
                    Text("Color").tag(ColorMode.color)
                }
                .pickerStyle(.segmented)
            }

            Section("System") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: Binding(
                        get: { viewModel.settings.launchAtLogin },
                        set: { viewModel.settings.launchAtLogin = $0 }
                    ))
                    if let error = viewModel.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Toggle("Enable notifications", isOn: Binding(
                    get: { viewModel.settings.notificationsEnabled },
                    set: {
                        viewModel.settings.notificationsEnabled = $0
                        viewModel.onNotificationsEnabledChanged($0)
                    }
                ))
            }
        }
        .formStyle(.grouped)
    }
}
