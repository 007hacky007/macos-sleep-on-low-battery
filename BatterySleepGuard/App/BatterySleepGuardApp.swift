import AppKit
import SwiftUI

@main
struct BatterySleepGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: appDelegate.viewModel)
        } label: {
            MenuBarLabel(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("Statistics", id: "statistics") {
            StatisticsView(viewModel: appDelegate.viewModel)
        }
        .defaultSize(width: 760, height: 620)

        Window("Processes", id: "processes") {
            ProcessesView(viewModel: appDelegate.viewModel)
        }
        .defaultSize(width: 640, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The test host must not touch the real history files next to the installed app.
    let viewModel = MenuBarViewModel(history: AppDelegate.isRunningTests
        ? HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "BatterySleepGuardTestHost"))
        : nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside this app; never monitor (or sleep) during a test run.
        guard !Self.isRunningTests else { return }
        viewModel.start()
    }

    private static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
