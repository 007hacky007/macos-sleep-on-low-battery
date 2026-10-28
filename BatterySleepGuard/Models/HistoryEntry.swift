import Foundation

/// One recorded battery reading, together with what the app derived from it at the time.
struct HistoryEntry: Equatable, Sendable, Identifiable {
    var timestamp: Date
    var percentage: Int
    var powerSource: PowerSource
    var isCharging: Bool
    /// Signed: negative while discharging, positive while charging.
    var batteryWatts: Double?
    var systemWatts: Double?
    var temperatureCelsius: Double?
    var drainPercentPerHour: Double?
    var timeToThreshold: TimeInterval?
    var keepAwakeHolding: Bool
    /// `MenuBarViewModel.Status` case name, kept as text so the file format does not depend on the enum.
    var status: String
    /// Added after the first release; rows written before it load as nil.
    var adapterInputWatts: Double?

    var id: Date { timestamp }

    var isDischarging: Bool { powerSource == .battery && !isCharging }
}

extension HistoryEntry {
    init(reading: BatteryReading, estimate: DrainEstimate, keepAwakeHolding: Bool, status: String) {
        var rate: Double?
        var eta: TimeInterval?
        if case .draining(let percentPerHour, let timeToThreshold) = estimate {
            rate = percentPerHour
            eta = timeToThreshold
        }
        self.init(
            timestamp: reading.timestamp,
            percentage: reading.percentage,
            powerSource: reading.powerSource,
            isCharging: reading.isCharging,
            batteryWatts: reading.telemetry.batteryWatts,
            systemWatts: reading.telemetry.systemWatts,
            temperatureCelsius: reading.telemetry.temperatureCelsius,
            drainPercentPerHour: rate,
            timeToThreshold: eta,
            keepAwakeHolding: keepAwakeHolding,
            status: status,
            adapterInputWatts: reading.telemetry.adapterInputWatts
        )
    }
}

/// A state change worth seeing on a chart or in a log.
struct HistoryEvent: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case launch
        case wake
        case cycleReset
        case keepAwakeHeld
        case keepAwakeReleased
        case keepAwakeSuspended
        case keepAwakeError
        case sleepTriggered
        case sleepFailed
        case batteryError
        case guardEnabled
        case guardDisabled
        case pluggedIn
        case unplugged
        case displayOff
        case displayOn
        case earlyWarning
    }

    struct ID: Hashable, Sendable {
        let timestamp: Date
        let kind: Kind
    }

    var timestamp: Date
    var kind: Kind
    var message: String

    /// Two events can share a millisecond timestamp (a wake is followed by a cycle reset),
    /// so the id includes the kind to keep `ForEach` ids unique.
    var id: ID { ID(timestamp: timestamp, kind: kind) }

    /// The event for a change of power source between two readings, if any.
    static func powerSourceEvent(previous: PowerSource?, reading: BatteryReading) -> HistoryEvent? {
        guard let previous, previous != reading.powerSource else { return nil }
        switch reading.powerSource {
        case .ac:
            let adapter = reading.telemetry.adapterWatts.map { "\($0) W adapter" } ?? "Adapter"
            return HistoryEvent(timestamp: reading.timestamp, kind: .pluggedIn, message: adapter)
        case .battery:
            return HistoryEvent(timestamp: reading.timestamp, kind: .unplugged, message: "On battery")
        case .unknown:
            return nil
        }
    }
}

/// RFC 4180 style CSV for the history and events files. Timestamps are ISO 8601 UTC with
/// fractional seconds. Optional numbers are empty columns when nil.
enum HistoryCSV {
    static let entryHeader = "timestamp,percentage,powerSource,isCharging,batteryWatts,systemWatts,temperatureCelsius,drainPercentPerHour,timeToThreshold,keepAwakeHolding,status,adapterInputWatts"
    static let eventHeader = "timestamp,kind,message"

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: Entries

    static func line(for entry: HistoryEntry) -> String {
        [
            dateFormatter.string(from: entry.timestamp),
            String(entry.percentage),
            entry.powerSource.rawValue,
            String(entry.isCharging),
            number(entry.batteryWatts),
            number(entry.systemWatts),
            number(entry.temperatureCelsius),
            number(entry.drainPercentPerHour),
            number(entry.timeToThreshold),
            String(entry.keepAwakeHolding),
            quote(entry.status),
            number(entry.adapterInputWatts),
        ].joined(separator: ",")
    }

    static func entry(from line: String) -> HistoryEntry? {
        let fields = fields(from: line)
        // 11 columns before adapterInputWatts was added, 12 since.
        guard fields.count == 11 || fields.count == 12,
              let timestamp = timestamp(from: fields[0]),
              let percentage = Int(fields[1]),
              let powerSource = PowerSource(rawValue: fields[2]),
              let isCharging = Bool(fields[3]),
              let keepAwakeHolding = Bool(fields[9])
        else { return nil }
        return HistoryEntry(
            timestamp: timestamp,
            percentage: percentage,
            powerSource: powerSource,
            isCharging: isCharging,
            batteryWatts: Double(fields[4]),
            systemWatts: Double(fields[5]),
            temperatureCelsius: Double(fields[6]),
            drainPercentPerHour: Double(fields[7]),
            timeToThreshold: Double(fields[8]),
            keepAwakeHolding: keepAwakeHolding,
            status: fields[10],
            adapterInputWatts: fields.count > 11 ? Double(fields[11]) : nil
        )
    }

    // MARK: Events

    static func line(for event: HistoryEvent) -> String {
        [
            dateFormatter.string(from: event.timestamp),
            event.kind.rawValue,
            quote(event.message.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")),
        ].joined(separator: ",")
    }

    static func event(from line: String) -> HistoryEvent? {
        let fields = fields(from: line)
        guard fields.count == 3,
              let timestamp = timestamp(from: fields[0]),
              let kind = HistoryEvent.Kind(rawValue: fields[1])
        else { return nil }
        return HistoryEvent(timestamp: timestamp, kind: kind, message: fields[2])
    }

    // MARK: Timestamps

    /// Parses exactly the format this file writes, `yyyy-MM-ddTHH:mm:ss.SSSZ`, with plain
    /// arithmetic. `ISO8601DateFormatter` takes about 60 microseconds per date, which adds up to
    /// more than a second for a week of rows at launch; this takes a fraction of that.
    static func timestamp(from text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 24,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "."),
              bytes[23] == UInt8(ascii: "Z")
        else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = bytes[index]
                guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(digit - UInt8(ascii: "0"))
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              let millisecond = number(20..<23),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60
        else { return nil }

        // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's days_from_civil).
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468

        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + Double(millisecond) / 1000
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Field coding

    static func quote(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Splits one CSV line into fields, honouring double quotes and doubled quotes inside them.
    static func fields(from line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            switch (character, inQuotes) {
            case ("\"", false):
                inQuotes = true
            case ("\"", true):
                // A doubled quote inside a quoted field is a literal quote.
                var lookahead = iterator
                if lookahead.next() == "\"" {
                    current.append("\"")
                    iterator = lookahead
                } else {
                    inQuotes = false
                }
            case (",", false):
                fields.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.3f", value)
    }
}
