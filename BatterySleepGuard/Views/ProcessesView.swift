import SwiftUI

/// Processes of the last minutes rolled up under their top-level application, the way
/// Activity Monitor and the battery menu attribute energy.
struct ProcessesView: View {
    let viewModel: MenuBarViewModel
    /// Off screen nothing is built, so a closed window does not redraw every sample.
    @State private var visible = false

    var body: some View {
        Group {
            if visible { content }
        }
        .frame(minWidth: 520, minHeight: 320)
        .background(WindowVisibilityObserver { visible = $0 })
    }

    private var content: some View {
        let monitor = viewModel.processes
        return
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Top processes").font(.headline)
                if monitor.windowSeconds > 0 {
                    Text("last \(Formatting.duration(monitor.windowSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if monitor.groups.isEmpty {
                Text("Measuring, the first row appears after 20 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Application")
                            Text("CPU")
                            Text("Approx. power")
                            Text("Wake-ups/s")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider()
                        ForEach(monitor.groups) { group in
                            GridRow(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name).bold().lineLimit(1)
                                    Text(members(of: group))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(String(format: "%.1f%%", group.cpuPercent))
                                Text(group.approxWatts.map { String(format: "%.1f W", $0) } ?? "-")
                                Text(String(format: "%.0f", group.idleWakeupsPerSecond))
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
            Text("Each application row sums its child processes (a terminal includes the shells, builds and tools started from it). CPU 100% is one core. Power is the application's share of the measured system load above the day's idle floor; display, GPU and processes the app cannot read (other users, most system daemons) are not attributed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func members(of group: ProcessGroup) -> String {
        let shown = group.members.prefix(3).map { "\($0.name) \(Int($0.cpuPercent.rounded()))%" }
        let more = group.members.count - shown.count
        return shown.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : "")
    }
}
