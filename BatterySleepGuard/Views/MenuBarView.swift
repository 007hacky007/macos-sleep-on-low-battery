import SwiftUI

struct MenuBarLabel: View {
    let viewModel: MenuBarViewModel

    var body: some View {
        let icon = Image(systemName: viewModel.menuBarSymbol)
        if let text = viewModel.menuBarText {
            Text("\(icon) \(text)")
        } else {
            icon
        }
    }
}

struct MenuBarView: View {
    let viewModel: MenuBarViewModel
    @State private var showingSettings = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if showingSettings {
                SettingsView(viewModel: viewModel) { showingSettings = false }
            } else {
                mainContent
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(WindowVisibilityObserver { viewModel.setMenuVisible($0) })
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery Sleep Guard")
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { viewModel.settings.enabled },
                    set: { viewModel.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack {
                Text("Battery threshold")
                Spacer()
                Button {
                    viewModel.adjustThreshold(by: -1)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(viewModel.settings.thresholdPercentage <= AppSettings.thresholdRange.lowerBound)
                Text("\(viewModel.settings.thresholdPercentage)%")
                    .monospacedDigit()
                    .frame(minWidth: 40)
                Button {
                    viewModel.adjustThreshold(by: 1)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.settings.thresholdPercentage >= AppSettings.thresholdRange.upperBound)
            }

            Divider()

            keepAwakeSection

            Divider()

            TimelineView(.everyMinute) { context in
                details(now: context.date)
            }

            if let message = viewModel.batteryError?.errorDescription ?? viewModel.sleepError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Sleep now") { viewModel.sleepNow() }
                    .disabled(!viewModel.canSleep)
                Spacer()
                Button("Reset statistics") { viewModel.resetStatistics() }
            }

            Divider()

            HStack {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    openWindow(id: "statistics")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Statistics", systemImage: "chart.xyaxis.line")
                }
                Button {
                    openWindow(id: "processes")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Processes", systemImage: "cpu")
                }
                Spacer()
                Button("Quit") { viewModel.quit() }
            }
            .buttonStyle(.borderless)
        }
    }

    private var keepAwakeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Keep awake")
                Spacer()
                Toggle("Keep awake", isOn: Binding(
                    get: { viewModel.keepAwakeActive },
                    set: { viewModel.setKeepAwake($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            HStack {
                Picker("Duration", selection: Binding(
                    get: { viewModel.settings.keepAwakeDuration },
                    set: { viewModel.setKeepAwakeDuration($0) }
                )) {
                    ForEach(KeepAwakeDuration.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Toggle("Keep display on", isOn: Binding(
                    get: { viewModel.settings.keepDisplayAwake },
                    set: { viewModel.setKeepDisplayAwake($0) }
                ))
            }

            Toggle("Only while on AC power", isOn: Binding(
                get: { viewModel.settings.keepAwakeOnlyOnAC },
                set: { viewModel.setKeepAwakeOnlyOnAC($0) }
            ))

            if let message = keepAwakeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(viewModel.keepAwakeError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keepAwakeMessage: String? {
        if let error = viewModel.keepAwakeError { return error }
        guard viewModel.keepAwakeActive else { return nil }
        if let reason = viewModel.keepAwakeSuspensionReason { return reason }
        if let end = viewModel.keepAwakeEndDate, let remaining = viewModel.keepAwakeRemaining {
            return "Active until \(end.formatted(date: .omitted, time: .shortened)) (\(Formatting.duration(remaining)) left)."
        }
        return "Active until turned off."
    }

    private func details(now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Current battery", viewModel.reading.map { "\($0.percentage)%" } ?? "-")
            row("Power", powerText)
            if let reading = viewModel.reading, !reading.isOnBattery, let watts = reading.telemetry.adapterInputWatts {
                row("Adapter input", Formatting.watts(watts))
            }
            if let watts = viewModel.reading?.telemetry.systemWatts {
                row("System load", Formatting.watts(watts))
            }
            if let watts = viewModel.reading?.telemetry.batteryWatts {
                row("Battery", Formatting.batteryState(watts))
            }
            if let celsius = viewModel.reading?.telemetry.temperatureCelsius {
                row("Battery temperature", Formatting.temperature(celsius))
            }
            if let celsius = viewModel.reading?.telemetry.cpuTemperatureCelsius {
                row("CPU temperature", Formatting.temperature(celsius))
            }
            if let summary = viewModel.topProcessesSummary {
                row("Top processes", summary)
            }
            row("Monitoring started", viewModel.monitoringStartDate.formatted(date: .numeric, time: .shortened))
            row("Elapsed", Formatting.duration(now.timeIntervalSince(viewModel.monitoringStartDate)))
            row("Drain rate", drainRateText)
            row("Estimated sleep", estimatedSleepText(now: now))
            row("Status", statusText)
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var powerText: String {
        guard let reading = viewModel.reading else { return "-" }
        if let adapter = reading.telemetry.adapterWatts, !reading.isOnBattery {
            return "\(reading.powerDescription), \(adapter) W adapter"
        }
        return reading.powerDescription
    }

    private var drainRateText: String {
        switch viewModel.drainEstimate {
        case .unavailable: return "-"
        case .notOnBattery: return "Not draining"
        case .insufficientData: return "Measuring..."
        case .notDecreasing: return "Not decreasing"
        case .draining(let rate, _): return String(format: "%.1f%% / hour", rate)
        }
    }

    private func estimatedSleepText(now: Date) -> String {
        if let date = viewModel.estimatedSleepDate {
            let remaining = date.timeIntervalSince(now)
            guard remaining > 60 else { return "Imminent" }
            return "\(date.formatted(date: .omitted, time: .shortened)) (in \(Formatting.duration(remaining)))"
        }
        if viewModel.status == .monitoring, case .draining(_, nil) = viewModel.drainEstimate {
            return "Imminent"
        }
        return "-"
    }

    private var statusText: String {
        let threshold = viewModel.settings.thresholdPercentage
        switch viewModel.status {
        case .starting: return "Starting..."
        case .noBattery: return "No battery detected"
        case .batteryUnavailable: return "Battery information unavailable"
        case .disabled: return "Disabled"
        case .sleepTriggered: return "Sleep triggered, waiting for wake"
        case .onACPower: return "Monitoring (on AC power)"
        case .waitingForRecharge: return "Paused until battery is above \(threshold)%"
        case .monitoring: return "Monitoring"
        }
    }
}
