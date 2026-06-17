import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                detailContent
            }

            Divider()

            HStack {
                if let error = viewModel.saveError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Color.dangerRed)
                        .lineLimit(3)
                        .frame(maxWidth: 300, alignment: .trailing)
                }

                Spacer()

                if viewModel.isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundColor(Color.textSecondary)
                } else if viewModel.hasUnsavedChanges {
                    Button("Save Changes") {
                        Task {
                            _ = await viewModel.save()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.textTertiary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(SidebarItem.allCases, id: \.self) { item in
                sidebarRow(for: item)
            }

            Spacer()
        }
        .frame(width: 180)
        .background(Color.sidebarBg)
    }

    private func sidebarRow(for item: SidebarItem) -> some View {
        let isSelected = viewModel.selectedSidebarItem == item

        return Button {
            viewModel.selectedSidebarItem = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(item.displayName)
                    .font(.system(size: 13))
            }
            .foregroundColor(isSelected ? Color.textPrimary : Color.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.sidebarSelectedBg : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch viewModel.selectedSidebarItem {
        case .services:
            servicesTab
        case .general:
            generalTab
        case .about:
            aboutTab
        }
    }

    // MARK: - Services Tab

    private var servicesTab: some View {
        VStack(spacing: 0) {
            if viewModel.instances.isEmpty {
                EmptyStateGuideView {
                    viewModel.editingInstance = nil
                    viewModel.isPresentingEditor = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.instances) { instance in
                        InstanceCardView(
                            instance: instance,
                            onEdit: {
                                viewModel.editingInstance = instance
                                viewModel.isPresentingEditor = true
                            },
                            onDelete: {
                                viewModel.requestDelete(instance)
                            },
                            onToggleTracking: {
                                viewModel.setInstanceTrackingEnabled(
                                    uuid: instance.uuid,
                                    enabled: !instance.trackingEnabled
                                )
                            }
                        )
                    }
                    .onMove(perform: viewModel.moveInstances)
                }
                .listStyle(.plain)

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
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Auto-refresh interval", selection: Binding(
                    get: { viewModel.settings.refreshIntervalMinutes },
                    set: { viewModel.settings.refreshIntervalMinutes = $0 }
                )) {
                    ForEach(1...60, id: \.self) { minute in
                        Text("\(minute) minute\(minute == 1 ? "" : "s")").tag(minute)
                    }
                }
            }

            Section("Appearance") {
                Picker("Menu bar icon style", selection: Binding(
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
                            .foregroundColor(Color.warningYellow)
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

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("API Usage Status")
                .font(.headline)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.subheadline)
                .foregroundColor(Color.textSecondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SidebarItem Display

extension SidebarItem {
    var iconName: String {
        switch self {
        case .services: return "server.rack"
        case .general: return "gear"
        case .about: return "info.circle"
        }
    }

    var displayName: String {
        switch self {
        case .services: return "Services"
        case .general: return "General"
        case .about: return "About"
        }
    }
}