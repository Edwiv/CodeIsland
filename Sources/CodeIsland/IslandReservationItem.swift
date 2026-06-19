import AppKit

/// Reserves real menu-bar width with a transparent NSStatusItem so neighboring status
/// icons reflow (shift right, away from the floating island) instead of being half-covered
/// by it (R2). A floating panel can only paint *over* other apps' icons; only a real
/// NSStatusItem with a positive `length` makes AppKit relayout the menu-bar cluster.
///
/// IMPORTANT LIMITATION (notched Macs): macOS drops the status items nearest the notch when
/// the menu bar is full. Our reserved slot is left-most (nearest the notch), so on a crowded
/// bar the system hides it and no space is reserved — exactly when occlusion would occur.
/// There is no public API to force a status item left-most or to give it priority, so this
/// feature is best-effort: it helps when there is free room right of the notch, and silently
/// does nothing when the bar is already packed. Gated by `SettingsKey.reserveMenuBarWidth`.
@MainActor
final class IslandReservationItem {
    static let shared = IslandReservationItem()

    private var statusItem: NSStatusItem?
    private var settingsObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var lastWidth: CGFloat = -1
    private let clearanceMargin: CGFloat = 18

    func start() {
        sync()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    /// Width to reserve right of the notch: the island's active compact-bar right-half plus a
    /// margin, plus the half-notch the system wastes by anchoring the left-most slot under the
    /// notch. Mirrors `NotchPanelView.panelWidth` for the active (non-expanded) state.
    private func reservedWidth() -> CGFloat {
        let screen = ScreenDetector.preferredScreen
        let notchW = ScreenDetector.notchWidth(for: screen)
        let notchHeight = ScreenDetector.topBarHeight(for: screen)
        let scale = UserDefaults.standard.object(forKey: SettingsKey.collapsedWidthScale) != nil
            ? UserDefaults.standard.integer(forKey: SettingsKey.collapsedWidthScale)
            : SettingsDefaults.collapsedWidthScale
        let effectiveNotchW = NotchWidthMetrics.effectiveNotchWidth(notchW: notchW, collapsedWidthScale: scale)
        let mascotSize = min(27, notchHeight - 6)
        let wing = mascotSize + 14
        let toolExtra = screen.frame.width * 0.03   // matches NotchPanelView tool-status reserve
        // islandRightHalf + margin + the half-notch the left-most slot wastes under the notch.
        return (effectiveNotchW / 2) + wing + 10 + (toolExtra / 2) + clearanceMargin + (effectiveNotchW / 2)
    }

    private func sync() {
        guard SettingsManager.shared.reserveMenuBarWidth else {
            removeItem()
            return
        }
        let width = max(40, reservedWidth().rounded())
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: width)
            // Transparent + inert: the slot only reserves space; the island floats over it.
            if let button = item.button {
                button.image = nil
                button.title = ""
                button.isEnabled = false
                button.alphaValue = 0
            }
            statusItem = item
            lastWidth = width
        } else if abs(lastWidth - width) > 0.5 {
            statusItem?.length = width
            lastWidth = width
        }
    }

    private func removeItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            lastWidth = -1
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
