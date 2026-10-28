import Foundation

/// Prepares history rows for Swift Charts. Seven days at one row per 30 seconds is about
/// 20k rows; charts stay responsive at a few hundred points, so rows are averaged into
/// equally sized buckets.
enum ChartSeries {
    static let maxPoints = 600

    /// Events shown as vertical rules on the charts.
    static let markedEventKinds: Set<HistoryEvent.Kind> = [
        .wake, .cycleReset, .sleepTriggered, .keepAwakeHeld, .keepAwakeReleased, .keepAwakeSuspended, .pluggedIn, .unplugged,
    ]

    static func label(for kind: HistoryEvent.Kind) -> String {
        switch kind {
        case .launch: return "Launch"
        case .wake: return "Wake"
        case .cycleReset: return "Reset"
        case .keepAwakeHeld: return "Awake on"
        case .keepAwakeReleased: return "Awake off"
        case .keepAwakeSuspended: return "Awake paused"
        case .keepAwakeError: return "Awake error"
        case .sleepTriggered: return "Sleep"
        case .sleepFailed: return "Sleep failed"
        case .batteryError: return "Battery error"
        case .guardEnabled: return "Enabled"
        case .guardDisabled: return "Disabled"
        case .pluggedIn: return "Plugged in"
        case .unplugged: return "Unplugged"
        case .displayOff: return "Display off"
        case .displayOn: return "Display on"
        case .earlyWarning: return "Warning"
        }
    }

    /// Time spans during which the Mac was on AC power, for shading the charts. A run ends
    /// where the next battery row starts, or at the last row when the run is still open.
    static func acSpans(_ entries: [HistoryEntry]) -> [ClosedRange<Date>] {
        var spans: [ClosedRange<Date>] = []
        var start: Date?
        for entry in entries {
            if entry.powerSource == .ac {
                if start == nil { start = entry.timestamp }
            } else if let began = start {
                spans.append(began...entry.timestamp)
                start = nil
            }
        }
        if let began = start, let last = entries.last {
            spans.append(began...last.timestamp)
        }
        return spans
    }

    /// Vertical level (0, 1, 2, ...) for each event label so that labels of events closer
    /// together than `minimumGap` do not overlap: each one sits one step below the previous.
    static func labelLevels(for dates: [Date], minimumGap: TimeInterval) -> [Int] {
        var levels: [Int] = []
        var previous: Date?
        for date in dates {
            if let previous, date.timeIntervalSince(previous) < minimumGap {
                levels.append(levels.last! + 1)
            } else {
                levels.append(0)
            }
            previous = date
        }
        return levels
    }

    /// The row closest in time to `date`, for the hover readout.
    static func nearest(to date: Date, in entries: [HistoryEntry]) -> HistoryEntry? {
        entries.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
    }

    /// Gaps longer than this (sleep, app not running) break the chart lines.
    static let maxGap: TimeInterval = 5 * 60

    /// Averages rows into time buckets of (span / maxPoints) so the result has at most
    /// `maxPoints` rows. Buckets are by time, not by row count, so dense and sparse stretches
    /// keep their shape and nothing is averaged across a long gap. Each result keeps the first
    /// row's timestamp and categorical fields; numeric fields are the mean of the non-nil values.
    static func downsample(_ entries: [HistoryEntry], maxPoints: Int) -> [HistoryEntry] {
        guard maxPoints > 0, entries.count > maxPoints, let first = entries.first, let last = entries.last else { return entries }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span > 0 else { return entries }
        return downsample(entries, bucketLength: span / Double(maxPoints), maxBuckets: maxPoints)
    }

    /// Averages rows into buckets of a fixed length, measured from the first row. The last
    /// row sits exactly on the bucket boundary, so `maxBuckets` folds it into the last bucket.
    static func downsample(_ entries: [HistoryEntry], bucketLength: TimeInterval, maxBuckets: Int? = nil) -> [HistoryEntry] {
        guard bucketLength > 0, let first = entries.first else { return entries }
        var result: [HistoryEntry] = []
        var bucket: [HistoryEntry] = []
        var bucketIndex = 0
        for entry in entries {
            var index = Int(entry.timestamp.timeIntervalSince(first.timestamp) / bucketLength)
            if let maxBuckets { index = min(maxBuckets - 1, index) }
            if index != bucketIndex, !bucket.isEmpty {
                result.append(average(bucket))
                bucket = []
            }
            bucketIndex = index
            bucket.append(entry)
        }
        if !bucket.isEmpty { result.append(average(bucket)) }
        return result
    }

    /// What the charts draw for a range: the raw rows split at real gaps first, then each
    /// run averaged into buckets of (range / maxPoints). Splitting after downsampling would
    /// break every bucket apart once buckets are longer than `maxGap`.
    static func chartSegments(_ entries: [HistoryEntry], range: TimeInterval, maxPoints: Int) -> [[HistoryEntry]] {
        let bucketLength = maxPoints > 0 ? range / Double(maxPoints) : 0
        return segments(entries, maxGap: maxGap).map { downsample($0, bucketLength: bucketLength) }
    }

    private static func average(_ bucket: [HistoryEntry]) -> HistoryEntry {
        var result = bucket[0]
        result.percentage = Int((Double(bucket.map(\.percentage).reduce(0, +)) / Double(bucket.count)).rounded())
        result.batteryWatts = mean(bucket.compactMap(\.batteryWatts))
        result.systemWatts = mean(bucket.compactMap(\.systemWatts))
        result.temperatureCelsius = mean(bucket.compactMap(\.temperatureCelsius))
        result.drainPercentPerHour = mean(bucket.compactMap(\.drainPercentPerHour))
        result.timeToThreshold = mean(bucket.compactMap(\.timeToThreshold))
        result.adapterInputWatts = mean(bucket.compactMap(\.adapterInputWatts))
        return result
    }

    /// Splits rows into runs with no gap longer than `maxGap`, so each run is drawn as its
    /// own line and nothing is drawn across a sleep.
    static func segments(_ entries: [HistoryEntry], maxGap: TimeInterval) -> [[HistoryEntry]] {
        var segments: [[HistoryEntry]] = []
        var current: [HistoryEntry] = []
        for entry in entries {
            if let last = current.last, entry.timestamp.timeIntervalSince(last.timestamp) > maxGap {
                segments.append(current)
                current = []
            }
            current.append(entry)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Totals for the selected range.
    struct RangeSummary: Equatable {
        /// Over discharging stretches only.
        var drainPercentPerHour: Double?
        /// Time weighted, over pairs where both rows report system load.
        var averageSystemWatts: Double?
        /// Trapezoid integral of system load, in watt hours.
        var energyWattHours: Double?
        /// Time spent on battery.
        var batterySeconds: TimeInterval
    }

    /// Pairs further apart than this are a sleep or a stopped app, not a measurement, and are
    /// left out of the totals. Longer than `maxGap` because a flat battery only records a
    /// heartbeat every few minutes.
    static let summaryMaxGap: TimeInterval = 3600

    static func summary(_ entries: [HistoryEntry]) -> RangeSummary? {
        guard !entries.isEmpty else { return nil }
        var batterySeconds = 0.0
        var dischargeSeconds = 0.0
        var drop = 0.0
        var energyWattSeconds = 0.0
        var energySeconds = 0.0
        for (a, b) in zip(entries, entries.dropFirst()) {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            guard seconds > 0, seconds <= summaryMaxGap else { continue }
            if a.powerSource == .battery { batterySeconds += seconds }
            if a.isDischarging, b.isDischarging {
                dischargeSeconds += seconds
                drop += Double(a.percentage - b.percentage)
            }
            if let wa = a.systemWatts, let wb = b.systemWatts {
                energyWattSeconds += (wa + wb) / 2 * seconds
                energySeconds += seconds
            }
        }
        return RangeSummary(
            drainPercentPerHour: dischargeSeconds > 0 ? drop / dischargeSeconds * 3600 : nil,
            averageSystemWatts: energySeconds > 0 ? energyWattSeconds / energySeconds : nil,
            energyWattHours: energySeconds > 0 ? energyWattSeconds / 3600 : nil,
            batterySeconds: batterySeconds
        )
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
