import AppKit
import SwiftUI

/// Standalone window hosting the global aggregation dashboard — all agent sessions
/// across local + remote machines (R8). Modeled on SettingsWindowController.
@MainActor
final class DashboardWindowController {
    static let shared = DashboardWindowController()
    private var window: NSWindow?
    weak var appState: AppState?

    private var closeObserver: NSObjectProtocol?

    private func clearCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let appState else { return }
        let view = DashboardView(appState: appState)
        let hostingView = NSHostingView(rootView: view)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenW = screen?.frame.width ?? 1440
        let screenH = screen?.frame.height ?? 900
        let winW = min(1100, screenW * 0.72)
        let winH = min(720, screenH * 0.78)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.title = L10n.shared["dashboard_title"]
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hostingView
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        clearCloseObserver()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window = nil
                self?.clearCloseObserver()
                DispatchQueue.main.async {
                    // Only drop back to accessory when no other titled window remains visible —
                    // otherwise closing the dashboard would yank an open Settings window into
                    // accessory mode (and vice-versa). (critic §2.3)
                    let hasTitledWindow = NSApp.windows.contains {
                        $0.isVisible && $0.styleMask.contains(.titled)
                    }
                    if !hasTitledWindow {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }

        self.window = window
    }
}
