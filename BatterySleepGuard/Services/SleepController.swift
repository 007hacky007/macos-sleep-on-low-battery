import Foundation
import IOKit.pwr_mgt
import os

enum SleepError: LocalizedError {
    case launchFailed(String)
    case pmsetFailed(status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Could not run pmset: \(reason)"
        case .pmsetFailed(let status, let output):
            let detail = output.isEmpty ? "" : " (\(output))"
            return "pmset sleepnow failed with exit code \(status)\(detail)."
        }
    }
}

/// Forces system sleep with `pmset sleepnow`.
///
/// An explicit sleep request is not blocked by PreventUserIdleSystemSleep assertions
/// (Amphetamine, caffeinate -i, IDEs, agents), which only stop *idle* sleep.
struct SleepController: Sendable {
    static let pmsetURL = URL(fileURLWithPath: "/usr/bin/pmset")
    private static let logger = Logger(subsystem: "BatterySleepGuard", category: "SleepController")

    func sleepNow() async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                try Self.runPmset()
            } catch {
                // Same request through IOKit directly, in case pmset is missing or broken.
                let result = IOPMSleepSystem(IOPMFindPowerManagement(kIOMainPortDefault))
                Self.logger.error("pmset failed: \(error.localizedDescription, privacy: .public); IOPMSleepSystem returned \(result)")
                if result != kIOReturnSuccess { throw error }
            }
        }.value
    }

    private static func runPmset() throws {
        let process = Process()
        process.executableURL = pmsetURL
        process.arguments = ["sleepnow"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw SleepError.launchFailed(error.localizedDescription)
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SleepError.pmsetFailed(
                status: process.terminationStatus,
                output: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
