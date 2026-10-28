import Darwin
import Foundation

enum SystemClock {
    /// Most recent wake or boot time. Used at launch to detect that the Mac slept or
    /// rebooted while the app was not running, which also starts a new cycle.
    static func lastWakeOrBoot() -> Date? {
        [sysctlDate("kern.waketime"), sysctlDate("kern.boottime")].compactMap { $0 }.max()
    }

    private static func sysctlDate(_ name: String) -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }
}
