import SwiftUI

struct SettingsView: View {
    let viewModel: MenuBarViewModel
    let onDone: () -> Void
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onDone) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Settings")
                    .font(.headline)
            }

            Divider()

            Picker("Menu bar shows", selection: Binding(
                get: { viewModel.settings.menuBarText },
                set: { viewModel.setMenuBarText($0) }
            )) {
                ForEach(MenuBarText.allCases) { Text($0.label).tag($0) }
            }

            Toggle("Warn 10 minutes before sleep", isOn: Binding(
                get: { viewModel.settings.earlyWarning },
                set: { viewModel.setEarlyWarning($0) }
            ))
            .toggleStyle(.switch)

            HStack {
                Picker("Keep history", selection: Binding(
                    get: { viewModel.settings.historyRetentionDays },
                    set: { viewModel.setHistoryRetention(days: $0) }
                )) {
                    ForEach(AppSettings.retentionChoices, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .confirmationDialog("Delete all recorded history and events?", isPresented: $confirmingClear) {
                        Button("Clear history", role: .destructive) { viewModel.clearHistory() }
                    }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { viewModel.loginItemStatus == .enabled || viewModel.loginItemStatus == .requiresApproval },
                set: { viewModel.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)

            if viewModel.loginItemStatus == .requiresApproval {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approve Battery Sleep Guard in System Settings > General > Login Items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") { viewModel.openLoginItemsSettings() }
                }
            }

            if let error = viewModel.loginItemError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text("Notifications")
                Spacer()
                switch viewModel.notificationsAllowed {
                case true?:
                    Text("Allowed").foregroundStyle(.secondary)
                case false?:
                    Button("Open Settings") { viewModel.openNotificationSettings() }
                case nil:
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }

            Text("Keep awake only blocks idle sleep. The battery threshold always wins: at or below it the keep awake assertion is released and pmset sleepnow puts the Mac to sleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { viewModel.refreshLoginItemStatus() }
    }
}
