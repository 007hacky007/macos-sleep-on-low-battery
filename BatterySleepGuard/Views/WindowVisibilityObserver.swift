import AppKit
import SwiftUI

/// Reports whether the window hosting this view is on screen. The menu bar window is
/// ordered out rather than closed, and on recent macOS opening it no longer activates the
/// app, so neither view lifecycle nor app activation tells reliably when it is visible.
struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onChange = onChange
    }

    final class ObservingView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let center = NotificationCenter.default
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
                }
                // Still visible while the notification is delivered, so it is reported directly.
                observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(false) }
                })
            }
            report()
            // The window is usually ordered in only after its content moved into it.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report(_ forced: Bool? = nil) {
            let visible = forced ?? window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
