import Darwin
import Foundation
import Observation

/// Reads CPU time and idle wake-ups of every process the user may inspect, through libproc.
/// No subprocess and no root: processes of other users and most system daemons are skipped.
enum ProcessSampler {
    nonisolated static let timebase: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    /// `proc_taskinfo` reports CPU time in Mach time units, not nanoseconds.
    nonisolated static func seconds(machTicks: UInt64, timebase: mach_timebase_info) -> Double {
        Double(machTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Busy CPU seconds of all cores since boot: user, system and nice ticks over the clock rate.
    nonisolated static func systemCPUSeconds() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let busyTicks = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))
        return ticksPerSecond > 0 ? Double(busyTicks) / ticksPerSecond : nil
    }

    /// Parent and short name of every process from `sysctl KERN_PROC_ALL`, which, unlike
    /// libproc, answers for processes of other users too (needed to walk through `login`).
    nonisolated static func processTable() -> (parents: [Int32: Int32], names: [Int32: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return ([:], [:]) }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return ([:], [:]) }

        var parents: [Int32: Int32] = [:]
        var names: [Int32: String] = [:]
        for info in buffer.prefix(size / stride) {
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { continue }
            parents[pid] = info.kp_eproc.e_ppid
            names[pid] = withUnsafePointer(to: info.kp_proc.p_comm) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
        }
        return (parents, names)
    }

    nonisolated static func snapshot(now: Date) -> ProcessSnapshot {
        var (parents, names) = processTable()
        var pids = [Int32](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        var samples: [Int32: ProcessSample] = [:]
        samples.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { continue }

            guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let name = String(cString: nameBuffer)

            var wakeups: UInt64 = 0
            var usage = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if read == 0 { wakeups = usage.ri_pkg_idle_wkups }

            samples[pid] = ProcessSample(
                name: name,
                cpuSeconds: seconds(machTicks: task.pti_total_user + task.pti_total_system, timebase: timebase),
                idleWakeups: wakeups
            )
            names[pid] = name   // full name, where sysctl only has the first 16 characters
            if parents[pid] == nil { parents[pid] = 1 }
        }
        return ProcessSnapshot(date: now, samples: samples, systemCPUSeconds: systemCPUSeconds(), parents: parents, names: names)
    }
}

/// Keeps five minutes of process snapshots and ranks processes by CPU time over that window,
/// apportioning the CPU-attributable system power by share. One walk of about 1000 pids
/// takes a millisecond and runs off the main thread.
@MainActor
@Observable
final class ProcessEnergyMonitor {
    nonisolated static let interval: TimeInterval = 10
    nonisolated static let window: TimeInterval = 5 * 60
    nonisolated static let minimumCPUPercent = 0.5
    nonisolated static let limit = 10
    nonisolated static let groupLimit = 15

    private(set) var top: [ProcessUsage] = []
    /// Processes rolled up under their top-level ancestor, busiest first.
    private(set) var groups: [ProcessGroup] = []
    /// Actual span covered by `top`, which grows from 10 s to 5 min after start.
    private(set) var windowSeconds: TimeInterval = 0

    /// Supplied by the owner: CPU-attributable system power for the current window.
    @ObservationIgnored var attributableWatts: @MainActor () -> Double? = { nil }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ring: [ProcessSnapshot] = []
    @ObservationIgnored private var sampling = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ring = []
        top = []
        groups = []
        windowSeconds = 0
    }

    private func sample() {
        guard !sampling else { return }
        sampling = true
        Task.detached(priority: .utility) {
            let snapshot = ProcessSampler.snapshot(now: Date())
            await MainActor.run { self.append(snapshot) }
        }
    }

    private func append(_ snapshot: ProcessSnapshot) {
        sampling = false
        let cutoff = snapshot.date.addingTimeInterval(-(Self.window + Self.interval))
        ring = ring.filter { $0.date >= cutoff } + [snapshot]
        guard let oldest = ring.first, ring.count >= 2 else { return }
        windowSeconds = snapshot.date.timeIntervalSince(oldest.date)
        let watts = attributableWatts()
        top = ProcessUsageCalculator.usage(
            from: oldest, to: snapshot, attributableWatts: watts,
            minimumCPUPercent: Self.minimumCPUPercent, limit: Self.limit
        )
        groups = ProcessUsageCalculator.groups(
            from: oldest, to: snapshot, attributableWatts: watts,
            minimumCPUPercent: Self.minimumCPUPercent, limit: Self.groupLimit
        )
    }
}
