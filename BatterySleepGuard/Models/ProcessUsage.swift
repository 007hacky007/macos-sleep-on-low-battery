import Foundation

/// CPU time and wake-ups of one process at one instant.
struct ProcessSample: Equatable, Sendable {
    var name: String
    /// Total user plus system CPU time since the process started.
    var cpuSeconds: Double
    /// Total package idle wake-ups since the process started.
    var idleWakeups: UInt64
}

/// All readable processes at one instant.
struct ProcessSnapshot: Equatable, Sendable {
    var date: Date
    var samples: [Int32: ProcessSample]
    /// Busy CPU seconds of the whole system (all cores, all processes) since boot, from
    /// `host_statistics`. Lets shares account for processes the app cannot read.
    var systemCPUSeconds: Double?
    /// Parent pid of every process on the system, readable or not, from sysctl.
    var parents: [Int32: Int32] = [:]
    /// Name of every process on the system, from sysctl (or libproc when readable).
    var names: [Int32: String] = [:]
}

/// Processes rolled up under their top-level ancestor, the way Activity Monitor and the
/// macOS battery menu attribute energy: a terminal and everything started from it is one row.
struct ProcessGroup: Identifiable, Equatable, Sendable {
    /// Pid of the top-level ancestor (its parent is launchd).
    var id: Int32
    var name: String
    var cpuPercent: Double
    var cpuShare: Double
    var approxWatts: Double?
    var idleWakeupsPerSecond: Double
    /// Readable members, busiest first.
    var members: [ProcessUsage]
}

/// One row of the "top processes" table: usage over the window between two snapshots.
struct ProcessUsage: Identifiable, Equatable, Sendable {
    var pid: Int32
    var name: String
    /// Average cores busy times 100: 100 means one core fully used.
    var cpuPercent: Double
    /// Share of all measured CPU time in the window, 0 to 1.
    var cpuShare: Double
    /// `cpuShare` times the CPU-attributable system power; nil when power is not measured.
    var approxWatts: Double?
    var idleWakeupsPerSecond: Double

    var id: Int32 { pid }
}

/// Turns two snapshots into ranked usage rows. macOS gives a non-root app no per process
/// energy counter, so power is apportioned by CPU time share.
enum ProcessUsageCalculator {
    static func usage(
        from older: ProcessSnapshot, to newer: ProcessSnapshot,
        attributableWatts: Double?, minimumCPUPercent: Double, limit: Int
    ) -> [ProcessUsage] {
        rows(from: older, to: newer, attributableWatts: attributableWatts)
            .filter { $0.cpuPercent >= minimumCPUPercent }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }

    static func groups(
        from older: ProcessSnapshot, to newer: ProcessSnapshot,
        attributableWatts: Double?, minimumCPUPercent: Double, limit: Int
    ) -> [ProcessGroup] {
        let rows = rows(from: older, to: newer, attributableWatts: attributableWatts)
        var members: [Int32: [ProcessUsage]] = [:]
        for row in rows {
            members[topLevelAncestor(of: row.pid, parents: newer.parents), default: []].append(row)
        }
        return members
            .map { root, rows in
                let sorted = rows.sorted { $0.cpuPercent > $1.cpuPercent }
                let watts = sorted.compactMap(\.approxWatts)
                return ProcessGroup(
                    id: root,
                    name: newer.names[root] ?? sorted[0].name,
                    cpuPercent: sorted.map(\.cpuPercent).reduce(0, +),
                    cpuShare: sorted.map(\.cpuShare).reduce(0, +),
                    approxWatts: watts.isEmpty ? nil : watts.reduce(0, +),
                    idleWakeupsPerSecond: sorted.map(\.idleWakeupsPerSecond).reduce(0, +),
                    members: sorted
                )
            }
            .filter { $0.cpuPercent >= minimumCPUPercent }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(limit)
            .map { $0 }
    }

    /// Walks up until the parent is launchd (pid 1) or unknown.
    static func topLevelAncestor(of pid: Int32, parents: [Int32: Int32]) -> Int32 {
        var current = pid
        var hops = 0
        while let parent = parents[current], parent > 1, parents[parent] != nil, hops < 128 {
            current = parent
            hops += 1
        }
        return current
    }

    private static func rows(from older: ProcessSnapshot, to newer: ProcessSnapshot, attributableWatts: Double?) -> [ProcessUsage] {
        let seconds = newer.date.timeIntervalSince(older.date)
        guard seconds > 0 else { return [] }

        // Only processes present in both snapshots with the same name count; a reused pid
        // would otherwise show the new program with the old one's lifetime CPU time.
        var deltas: [(pid: Int32, name: String, cpu: Double, wakeups: Double)] = []
        for (pid, current) in newer.samples {
            guard let previous = older.samples[pid], previous.name == current.name else { continue }
            let cpu = max(0, current.cpuSeconds - previous.cpuSeconds)
            let wakeups = Double(current.idleWakeups >= previous.idleWakeups ? current.idleWakeups - previous.idleWakeups : 0)
            deltas.append((pid, current.name, cpu, wakeups))
        }
        // Shares are taken of the system-wide busy time when it is known, so CPU burnt by
        // unreadable processes (WindowServer, root daemons) stays unattributed instead of
        // being handed to the visible rows. Tick granularity can put the system figure below
        // the readable sum, hence the max.
        let readableCPU = deltas.map(\.cpu).reduce(0, +)
        var totalCPU = readableCPU
        if let newerTotal = newer.systemCPUSeconds, let olderTotal = older.systemCPUSeconds {
            totalCPU = max(readableCPU, newerTotal - olderTotal)
        }
        guard totalCPU > 0 else { return [] }

        return deltas.map { delta in
            let share = delta.cpu / totalCPU
            return ProcessUsage(
                pid: delta.pid,
                name: delta.name,
                cpuPercent: delta.cpu / seconds * 100,
                cpuShare: share,
                approxWatts: attributableWatts.map { share * $0 },
                idleWakeupsPerSecond: delta.wakeups / seconds
            )
        }
    }

    /// Below this the estimate is noise and the column shows "-" rather than "0.0 W".
    static let minimumAttributableWatts = 0.5

    /// Power that CPU activity can be blamed for: the average system load over the window
    /// above the idle floor. nil when load is not measured or there is nothing to attribute.
    static func attributableWatts(averageLoad: Double?, idleFloor: Double?) -> Double? {
        guard let averageLoad else { return nil }
        let watts = averageLoad - (idleFloor ?? 0)
        return watts >= minimumAttributableWatts ? watts : nil
    }
}
