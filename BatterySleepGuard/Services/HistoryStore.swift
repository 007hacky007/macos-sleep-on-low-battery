import Foundation
import Observation
import os

/// Keeps recent battery readings and state change events in memory and in two CSV files,
/// so charts and debugging can look back over the last days.
///
/// Rows older than the retention are dropped from memory on every record, and the files
/// are rewritten without them on load and at most once an hour while running, so the file
/// size stays bounded by the retention rather than by uptime. Rewrites happen in place
/// (truncate and write, no rename), so another instance of the store on the same files,
/// such as the test host next to the installed app, keeps appending to a valid file.
/// Writes never throw into the caller: a failed write is logged once and monitoring
/// continues with the in-memory copy.
@MainActor
@Observable
final class HistoryStore {
    nonisolated static let retention: TimeInterval = 7 * 24 * 3600
    /// Readings closer together than this are skipped unless the battery state changed.
    nonisolated static let minimumInterval: TimeInterval = 30
    /// How often, at most, the files are rewritten to drop expired rows while running.
    nonisolated static let rewriteInterval: TimeInterval = 3600
    nonisolated static let historyFileName = "history.csv"
    nonisolated static let eventsFileName = "events.csv"

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "BatterySleepGuard", directoryHint: .isDirectory)
    }

    private(set) var entries: [HistoryEntry] = []
    private(set) var events: [HistoryEvent] = []

    let directoryURL: URL
    @ObservationIgnored private var retention: TimeInterval
    var retentionDays: Int { Int((retention / 86_400).rounded()) }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var historyHandle: FileHandle?
    @ObservationIgnored private var eventsHandle: FileHandle?
    @ObservationIgnored private var reportedWriteFailure = false
    @ObservationIgnored private var lastRewrite: Date
    @ObservationIgnored private let logger = Logger(subsystem: "BatterySleepGuard", category: "HistoryStore")

    init(directory: URL, retention: TimeInterval = HistoryStore.retention, now: @escaping () -> Date = Date.init) {
        directoryURL = directory
        self.retention = retention
        self.now = now
        lastRewrite = now()
        load()
    }

    // MARK: - Pure rules

    static func shouldRecord(_ entry: HistoryEntry, after last: HistoryEntry?, minimumInterval: TimeInterval) -> Bool {
        guard let last else { return true }
        let changed = last.percentage != entry.percentage
            || last.powerSource != entry.powerSource
            || last.isCharging != entry.isCharging
        return changed || entry.timestamp.timeIntervalSince(last.timestamp) >= minimumInterval
    }

    static func pruned<T>(_ items: [T], cutoff: Date, timestamp: (T) -> Date) -> [T] {
        items.filter { timestamp($0) >= cutoff }
    }

    // MARK: - Recording

    func record(_ entry: HistoryEntry) {
        guard Self.shouldRecord(entry, after: entries.last, minimumInterval: Self.minimumInterval) else { return }
        let kept = Self.pruned(entries, cutoff: cutoff, timestamp: \.timestamp)
        let expired = kept.count != entries.count
        entries = kept + [entry]
        if expired, rewriteDue {
            rewriteAll()
        } else {
            append(HistoryCSV.line(for: entry), to: \.historyHandle, fileName: Self.historyFileName, header: HistoryCSV.entryHeader)
        }
    }

    func record(_ event: HistoryEvent) {
        let kept = Self.pruned(events, cutoff: cutoff, timestamp: \.timestamp)
        let expired = kept.count != events.count
        events = kept + [event]
        if expired, rewriteDue {
            rewriteAll()
        } else {
            append(HistoryCSV.line(for: event), to: \.eventsHandle, fileName: Self.eventsFileName, header: HistoryCSV.eventHeader)
        }
    }

    /// Applies a new retention at once: memory and files are pruned and rewritten.
    func setRetention(days: Int) {
        retention = TimeInterval(days) * 86_400
        entries = Self.pruned(entries, cutoff: cutoff, timestamp: \.timestamp)
        events = Self.pruned(events, cutoff: cutoff, timestamp: \.timestamp)
        rewriteAll()
    }

    /// Drops every row; the files keep their headers.
    func clear() {
        entries = []
        events = []
        rewriteAll()
    }

    // MARK: - Queries

    func entries(in range: TimeInterval) -> [HistoryEntry] {
        let start = now().addingTimeInterval(-range)
        return entries.filter { $0.timestamp >= start }
    }

    func events(in range: TimeInterval) -> [HistoryEvent] {
        let start = now().addingTimeInterval(-range)
        return events.filter { $0.timestamp >= start }
    }

    func exportCSV(range: TimeInterval) -> String {
        ([HistoryCSV.entryHeader] + entries(in: range).map(HistoryCSV.line(for:))).joined(separator: "\n") + "\n"
    }

    // MARK: - Files

    private var cutoff: Date { now().addingTimeInterval(-retention) }
    private var rewriteDue: Bool { now().timeIntervalSince(lastRewrite) >= Self.rewriteInterval }

    private var historyURL: URL { directoryURL.appending(path: Self.historyFileName) }
    private var eventsURL: URL { directoryURL.appending(path: Self.eventsFileName) }

    private func load() {
        let (loadedEntries, entriesDropped) = Self.loadRows(at: historyURL, header: HistoryCSV.entryHeader, parse: HistoryCSV.entry(from:), cutoff: cutoff, timestamp: \.timestamp)
        entries = loadedEntries
        if entriesDropped {
            rewrite(url: historyURL, header: HistoryCSV.entryHeader, lines: entries.map(HistoryCSV.line(for:)))
        }

        let (loadedEvents, eventsDropped) = Self.loadRows(at: eventsURL, header: HistoryCSV.eventHeader, parse: HistoryCSV.event(from:), cutoff: cutoff, timestamp: \.timestamp)
        events = loadedEvents
        if eventsDropped {
            rewrite(url: eventsURL, header: HistoryCSV.eventHeader, lines: events.map(HistoryCSV.line(for:)))
        }
    }

    /// Returns the rows still inside the retention and whether the file should be rewritten:
    /// something was dropped (expired, malformed) or the header is from an older version.
    private static func loadRows<T>(
        at url: URL, header: String, parse: (String) -> T?, cutoff: Date, timestamp: (T) -> Date
    ) -> (rows: [T], dropped: Bool) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return ([], false) }
        let allLines = contents.split(whereSeparator: \.isNewline)
        let staleHeader = allLines.first.map { $0 != header } ?? false
        let lines = allLines.dropFirst()
        let parsed = lines.compactMap { parse(String($0)) }
        let kept = pruned(parsed, cutoff: cutoff, timestamp: timestamp)
        return (kept, staleHeader || kept.count != lines.count)
    }

    /// Both files are rewritten from memory, dropping expired rows.
    private func rewriteAll() {
        lastRewrite = now()
        rewrite(url: historyURL, header: HistoryCSV.entryHeader, lines: entries.map(HistoryCSV.line(for:)))
        rewrite(url: eventsURL, header: HistoryCSV.eventHeader, lines: events.map(HistoryCSV.line(for:)))
    }

    /// Truncates and rewrites the file in place. An atomic write would rename a new file over
    /// the old one and leave any other open handle, in this or another process, writing to an
    /// unlinked inode.
    private func rewrite(url: URL, header: String, lines: [String]) {
        let contents = ([header] + lines).joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(contents.utf8))
        } catch {
            reportWriteFailure(error)
        }
    }

    private func append(
        _ line: String, to handleKeyPath: ReferenceWritableKeyPath<HistoryStore, FileHandle?>, fileName: String, header: String
    ) {
        do {
            if self[keyPath: handleKeyPath] == nil {
                self[keyPath: handleKeyPath] = try openForAppending(fileName: fileName, header: header)
            }
            guard let handle = self[keyPath: handleKeyPath] else { return }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            self[keyPath: handleKeyPath] = nil
            reportWriteFailure(error)
        }
    }

    private func openForAppending(fileName: String, header: String) throws -> FileHandle {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appending(path: fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        return try FileHandle(forWritingTo: url)
    }

    private func reportWriteFailure(_ error: Error) {
        guard !reportedWriteFailure else { return }
        reportedWriteFailure = true
        logger.error("History write failed, continuing in memory only: \(error.localizedDescription, privacy: .public)")
    }
}
