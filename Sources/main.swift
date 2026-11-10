import AppKit
import ApplicationServices

/// Menu-bar application coordinator. All UI, preferences, and lifecycle
/// notifications are handled on the main thread without background polling.
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    /// Persistent master switch and speed gain.
    private let preferences = Preferences()
    /// Owns the only mouse event worker.
    private let engine = MouseEngine()
    /// Keeps the menu-bar icon alive for the application lifetime.
    private var statusItem: NSStatusItem?
    /// Settings are created once when requested, not during normal login startup.
    private var settings: SettingsWindow?
    /// Menu checkbox mirrors the persistent master switch.
    private var enabledMenuItem: NSMenuItem?
    /// Menu status is refreshed on state transitions and when opened.
    private var stateMenuItem: NSMenuItem?
    /// Sleep lifecycle prevents a live event tap while the machine sleeps.
    private var asleep = false
    /// Cached display bounds change only with screen layout notifications.
    private var displays: [CGRect] = []
    /// Notification tokens are retained for deterministic removal at termination.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Installs menu and sparse lifecycle notifications, then applies settings.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let peers = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.local.MouseYBoost")
        guard !peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        updateDisplays()
        engine.onStateChanged = { [weak self] _ in self?.refreshInterface() }
        observe(NSApplication.didChangeScreenParametersNotification,
                center: .default) { [weak self] in
            self?.updateDisplays()
            self?.applyPreferences()
        }
        observe(NSWorkspace.willSleepNotification,
                center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.asleep = true
            self?.applyPreferences()
        }
        observe(NSWorkspace.didWakeNotification,
                center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.asleep = false
            self?.updateDisplays()
            self?.applyPreferences()
        }
        observe(NSWorkspace.sessionDidResignActiveNotification,
                center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.asleep = true
            self?.applyPreferences()
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification,
                center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.asleep = false
            self?.updateDisplays()
            self?.applyPreferences()
        }
        applyPreferences()
        let shouldShow = !preferences.hasLaunched
            || ProcessInfo.processInfo.arguments.contains("--settings")
        preferences.hasLaunched = true
        if shouldShow { showSettings() }
    }

    /// Returning from System Settings is an event-driven permission refresh.
    func applicationDidBecomeActive(_ notification: Notification) { applyPreferences() }

    /// Reopening the installed app presents the existing settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                      hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Closing settings leaves the menu-bar utility running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Removes the worker and notification observers before process exit.
    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// Creates a compact template icon and basic menu without periodic updates.
    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "arrow.up.and.down",
                               accessibilityDescription: "MouseYBoost") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "Y"
        }
        item.button?.toolTip = "MouseYBoost · 鼠标纵向速度"
        let menu = NSMenu()
        let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateMenuItem = stateItem
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let enabledItem = NSMenuItem(title: "启用纵向增益",
                                     action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        enabledMenuItem = enabledItem
        menu.addItem(enabledItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 MouseYBoost", action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    /// Reads the current public display geometry once per layout/lifecycle event.
    private func updateDisplays() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = []
            return
        }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &identifiers, &count) == .success else { return }
        displays = identifiers.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Reconciles permission and preferences with the actual worker lifecycle.
    private func applyPreferences() {
        engine.apply(enabled: preferences.enabled, gain: preferences.verticalGain,
                     trusted: AXIsProcessTrusted(), asleep: asleep, displays: displays)
        refreshInterface()
    }

    /// Refreshes visible controls only in response to state or user activity.
    private func refreshInterface() {
        enabledMenuItem?.state = preferences.enabled ? .on : .off
        stateMenuItem?.title = String(format: "%.2f 倍 · ", preferences.verticalGain) + engine.state.text
        settings?.refresh(state: engine.state, trusted: AXIsProcessTrusted())
    }

    /// Adds one main-queue observer and retains its token for cleanup.
    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        observers.append((center, token))
    }

    /// Lazily constructs settings, refreshes permissions, and focuses the window.
    @objc private func showSettings() {
        if settings == nil {
            let controller = SettingsWindow(preferences: preferences)
            controller.onPreferencesChanged = { [weak self] in self?.applyPreferences() }
            controller.onRefreshRequested = { [weak self] in self?.applyPreferences() }
            settings = controller
        }
        applyPreferences()
        settings?.present()
    }

    /// Menu-bar shortcut toggles processing without opening a settings window.
    @objc private func toggleEnabled() {
        preferences.enabled.toggle()
        applyPreferences()
    }

    /// Quitting leaves the user's enabled/gain/login preferences intact.
    @objc private func quit() { NSApp.terminate(nil) }
}

/// AppKit retains its delegate weakly, so this top-level reference lives through run().
let delegate = ApplicationDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
