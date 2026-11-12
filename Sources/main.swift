import AppKit
import ApplicationServices

/// Menu-bar application coordinator. All UI, preferences, and lifecycle
/// notifications are handled on the main thread without background polling.
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Persistent independent switches and speed multipliers for both devices.
    private let preferences = Preferences()
    /// Owns the only mouse event worker.
    private let engine = MouseEngine()
    /// Keeps the menu-bar icon alive for the application lifetime.
    private var statusItem: NSStatusItem?
    /// Settings are created once when requested, not during normal login startup.
    private var settings: SettingsWindow?
    /// Menu checkbox mirrors the saved mouse switch without gating the trackpad.
    private var mouseEnabledMenuItem: NSMenuItem?
    /// Menu checkbox mirrors the independent trackpad switch so either device
    /// can be enabled or disabled without opening the settings window.
    private var trackpadEnabledMenuItem: NSMenuItem?
    /// Menu status is refreshed on state transitions and when opened.
    private var stateMenuItem: NSMenuItem?
    /// Read-only mouse multiplier mirrors the mouse settings row to hundredths.
    private let mouseGainMenuLabel = NSTextField(labelWithString: "")
    /// Mouse-only arrows remain usable without dismissing the menu each step.
    private let mouseGainMenuStepper = NSStepper()
    /// Read-only trackpad multiplier never follows changes to the mouse value.
    private let trackpadGainMenuLabel = NSTextField(labelWithString: "")
    /// Trackpad-only arrows write the same independent value as its settings row.
    private let trackpadGainMenuStepper = NSStepper()
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
        buildApplicationMenu()
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

    /// Supplies the standard Cocoa responder-chain editing commands. An
    /// accessory application still needs a main menu for Command-A/C/V and
    /// undo/redo inside its settings text field to work normally.
    private func buildApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "MouseYBoost")
        applicationMenu.addItem(withTitle: "退出 MouseYBoost",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// Creates a compact icon and separate menu groups for mouse and trackpad,
    /// each with its own multiplier arrows and independent enable checkbox.
    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "arrow.up.and.down",
                               accessibilityDescription: "MouseYBoost") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "Y"
        }
        item.button?.toolTip = "MouseYBoost · 鼠标与触控板纵向速度"
        let menu = NSMenu()
        menu.delegate = self
        let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateMenuItem = stateItem
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(makeGainMenuItem(title: "鼠标纵向增益", label: mouseGainMenuLabel,
                                      stepper: mouseGainMenuStepper,
                                      action: #selector(changeMouseGainFromMenu(_:))))
        let mouseItem = NSMenuItem(title: "启用鼠标纵向增益",
                                   action: #selector(toggleMouseEnabled), keyEquivalent: "")
        mouseItem.target = self
        mouseEnabledMenuItem = mouseItem
        menu.addItem(mouseItem)
        menu.addItem(.separator())
        menu.addItem(makeGainMenuItem(title: "触控板纵向增益", label: trackpadGainMenuLabel,
                                      stepper: trackpadGainMenuStepper,
                                      action: #selector(changeTrackpadGainFromMenu(_:))))
        let trackpadItem = NSMenuItem(title: "启用触控板纵向增益",
                                      action: #selector(toggleTrackpadEnabled), keyEquivalent: "")
        trackpadItem.target = self
        trackpadEnabledMenuItem = trackpadItem
        menu.addItem(trackpadItem)
        menu.addItem(.separator())
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

    /// Builds one device's menu row using its own retained label, stepper, and
    /// action. Both rows use the 1–5 range and 0.1 steps without sharing state,
    /// wrapping at bounds, or repeatedly changing gain while an arrow is held.
    private func makeGainMenuItem(title text: String, label: NSTextField,
                                  stepper: NSStepper, action: Selector) -> NSMenuItem {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 38))
        row.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: text)
        title.font = .menuFont(ofSize: 0)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                               weight: .medium)
        label.alignment = .right
        label.setAccessibilityLabel(text + "当前倍数")
        stepper.minValue = 1
        stepper.maxValue = 5
        stepper.increment = 0.1
        stepper.valueWraps = false
        stepper.autorepeat = false
        stepper.target = self
        stepper.action = action
        stepper.toolTip = "上调增加 0.1 倍，下调减少 0.1 倍（范围 1～5 倍）"
        stepper.setAccessibilityLabel(text + "倍数")
        for view in [title, label, stepper] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: label.leadingAnchor,
                                            constant: -20),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 76),
            label.trailingAnchor.constraint(equalTo: stepper.leadingAnchor, constant: -10),
            stepper.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stepper.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
        ])
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.view = row
        return item
    }

    /// Reconciles the current gain and permission state each time the user opens
    /// the dropdown, without a timer or changing any saved preferences.
    func menuWillOpen(_ menu: NSMenu) { applyPreferences() }

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
        engine.apply(mouseEnabled: preferences.mouseEnabled,
                     trackpadEnabled: preferences.trackpadEnabled,
                     mouseGain: preferences.mouseVerticalGain,
                     trackpadGain: preferences.trackpadVerticalGain,
                     trusted: AXIsProcessTrusted(), asleep: asleep, displays: displays)
        refreshInterface()
    }

    /// Refreshes visible controls only in response to state or user activity.
    private func refreshInterface() {
        mouseEnabledMenuItem?.state = preferences.mouseEnabled ? .on : .off
        trackpadEnabledMenuItem?.state = preferences.trackpadEnabled ? .on : .off
        stateMenuItem?.title = engine.state.text
        mouseGainMenuLabel.stringValue = String(format: "%.2f 倍", preferences.mouseVerticalGain)
        mouseGainMenuStepper.doubleValue = preferences.mouseVerticalGain
        trackpadGainMenuLabel.stringValue = String(format: "%.2f 倍", preferences.trackpadVerticalGain)
        trackpadGainMenuStepper.doubleValue = preferences.trackpadVerticalGain
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

    /// Toggles only mouse gain from the menu, preserving trackpad eligibility.
    @objc private func toggleMouseEnabled() {
        preferences.mouseEnabled.toggle()
        applyPreferences()
    }

    /// Toggles only trackpad gain from the menu, preserving the mouse switch and
    /// either saved multiplier. This remains available while mouse gain is off.
    @objc private func toggleTrackpadEnabled() {
        preferences.trackpadEnabled.toggle()
        applyPreferences()
    }

    /// Changes only mouse gain by one menu step. Refresh updates the settings
    /// editor even if it still has focus, preventing stale text from reappearing.
    @objc private func changeMouseGainFromMenu(_ sender: NSStepper) {
        preferences.mouseVerticalGain = sender.doubleValue
        applyPreferences()
    }

    /// Changes only trackpad gain and immediately refreshes both surfaces from
    /// its saved value, leaving the mouse multiplier and both switches unchanged.
    @objc private func changeTrackpadGainFromMenu(_ sender: NSStepper) {
        preferences.trackpadVerticalGain = sender.doubleValue
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
