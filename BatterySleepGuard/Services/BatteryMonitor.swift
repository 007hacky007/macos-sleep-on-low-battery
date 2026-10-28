import Foundation
import IOKit
import IOKit.ps

enum BatteryError: LocalizedError, Equatable {
    case powerSourceInfoUnavailable
    case noBattery
    case missingCapacity

    var errorDescription: String? {
        switch self {
        case .powerSourceInfoUnavailable: return "macOS did not return power source information."
        case .noBattery: return "No internal battery found. This Mac runs on AC power only."
        case .missingCapacity: return "The battery did not report its charge level."
        }
    }
}

/// Reads the internal battery through IOKit every 30 seconds and whenever macOS reports
/// a power source change (plugging in, unplugging, percentage updates).
@MainActor
final class BatteryMonitor {
    static let refreshInterval: TimeInterval = 30
    /// Used while the menu bar window is open, so watts and temperature stay current.
    static let liveRefreshInterval: TimeInterval = 5

    var onUpdate: ((Result<BatteryReading, BatteryError>) -> Void)?

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?
    private var interval = BatteryMonitor.refreshInterval
    private let cpuTemperature = CPUTemperatureSensor()

    func start() {
        stop()
        scheduleTimer()
        installPowerSourceNotification()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
    }

    func refresh() {
        // Only shown in the menu bar window, so it is not read while the window is closed.
        let live = interval == Self.liveRefreshInterval
        onUpdate?(Self.readBattery().map { reading in
            var reading = reading
            if live { reading.telemetry.cpuTemperatureCelsius = cpuTemperature.read() }
            return reading
        })
    }

    func setLiveUpdates(_ live: Bool) {
        let newInterval = live ? Self.liveRefreshInterval : Self.refreshInterval
        guard newInterval != interval else { return }
        interval = newInterval
        if timer != nil {
            scheduleTimer()
            if live { refresh() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval / 6
        // Common modes keep the timer firing while the menu bar window is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installPowerSourceNotification() {
        // The monitor lives as long as the app, so an unretained context pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    nonisolated static func readBattery(now: Date = Date()) -> Result<BatteryReading, BatteryError> {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .failure(.powerSourceInfoUnavailable) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true
            else { continue }

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { return .failure(.missingCapacity) }

            let percentage = Int((Double(current) / Double(maximum) * 100).rounded())
            let powerSource: PowerSource
            switch description[kIOPSPowerSourceStateKey] as? String {
            case kIOPSBatteryPowerValue: powerSource = .battery
            case kIOPSACPowerValue: powerSource = .ac
            default: powerSource = .unknown
            }

            return .success(BatteryReading(
                timestamp: now,
                percentage: min(max(percentage, 0), 100),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                powerSource: powerSource,
                telemetry: readTelemetry()
            ))
        }
        return .failure(.noBattery)
    }

    /// Watts and temperature are not part of the power source description; they come from
    /// the battery driver's IORegistry entry.
    nonisolated static func readTelemetry() -> BatteryTelemetry {
        guard let battery = registryProperties(ofClass: "AppleSmartBattery") else { return BatteryTelemetry() }
        return BatteryTelemetry.parse(battery: battery, pack: registryProperties(ofClass: "AppleSmartBatteryPack"))
    }

    private nonisolated static func registryProperties(ofClass className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return properties?.takeRetainedValue() as? [String: Any]
    }
}
