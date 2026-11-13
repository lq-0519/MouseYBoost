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
    /// Left mouse button subtracts one 0.1 step with a larger click target than
    /// a split stepper; it is disabled only when the mouse gain reaches 1.
    private let mouseGainDecreaseButton = NSButton(title: "−", target: nil, action: nil)
    /// Right mouse button adds one 0.1 step independently of trackpad settings
    /// and is disabled when the saved mouse multiplier reaches 5.
    private let mouseGainIncreaseButton = NSButton(title: "+", target: nil, action: nil)
    /// Read-only trackpad multiplier never follows changes to the mouse value.
    private let trackpadGainMenuLabel = NSTextField(labelWithString: "")
    /// Left trackpad button reduces only the trackpad multiplier by 0.1, using
    /// the same larger hit area and minimum-value behavior as the mouse row.
    private let trackpadGainDecreaseButton = NSButton(title: "−", target: nil, action: nil)
    /// Right trackpad button increases only the trackpad multiplier by 0.1;
    /// its enabled state follows the trackpad value rather than the mouse value.
    private let trackpadGainIncreaseButton = NSButton(title: "+", target: nil, action: nil)
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
    /// each with its own left/right gain buttons and independent enable checkbox.
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
                                      decreaseButton: mouseGainDecreaseButton,
                                      increaseButton: mouseGainIncreaseButton,
                                      action: #selector(changeMouseGainFromMenu(_:))))
        let mouseItem = NSMenuItem(title: "启用鼠标纵向增益",
                                   action: #selector(toggleMouseEnabled), keyEquivalent: "")
        mouseItem.target = self
        mouseEnabledMenuItem = mouseItem
        menu.addItem(mouseItem)
        menu.addItem(.separator())
        menu.addItem(makeGainMenuItem(title: "触控板纵向增益", label: trackpadGainMenuLabel,
                                      decreaseButton: trackpadGainDecreaseButton,
                                      increaseButton: trackpadGainIncreaseButton,
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

    /// Builds one device's menu row as a left minus button, centered multiplier,
    /// and right plus button. Separate 36×32 targets make both directions easier
    /// to click; momentary buttons apply one step per click and keep the menu open.
    /// Tags carry only the step direction, while each row retains its own action.
    private func makeGainMenuItem(title text: String, label: NSTextField,
                                  decreaseButton: NSButton, increaseButton: NSButton,
                                  action: Selector) -> NSMenuItem {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 46))
        row.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: text)
        title.font = .menuFont(ofSize: 0)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                               weight: .medium)
        label.alignment = .center
        label.setAccessibilityLabel(text + "当前倍数")
        decreaseButton.tag = -1
        increaseButton.tag = 1
        for button in [decreaseButton, increaseButton] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.setButtonType(.momentaryPushIn)
            button.font = .systemFont(ofSize: 18, weight: .medium)
            button.target = self
            button.action = action
            let direction = button.tag < 0 ? "减小" : "增大"
            button.toolTip = direction + text + " 0.1 倍（范围 1～5 倍）"
            button.setAccessibilityLabel(direction + text + " 0.1 倍")
        }
        for view in [title, label, decreaseButton, increaseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: decreaseButton.leadingAnchor,
                                            constant: -16),
            decreaseButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            decreaseButton.widthAnchor.constraint(equalToConstant: 36),
            decreaseButton.heightAnchor.constraint(equalToConstant: 32),
            decreaseButton.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 76),
            label.trailingAnchor.constraint(equalTo: increaseButton.leadingAnchor, constant: -8),
            increaseButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            increaseButton.widthAnchor.constraint(equalToConstant: 36),
            increaseButton.heightAnchor.constraint(equalToConstant: 32),
            increaseButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
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
        mouseGainDecreaseButton.isEnabled = preferences.mouseVerticalGain > 1
        mouseGainIncreaseButton.isEnabled = preferences.mouseVerticalGain < 5
        trackpadGainMenuLabel.stringValue = String(format: "%.2f 倍", preferences.trackpadVerticalGain)
        trackpadGainDecreaseButton.isEnabled = preferences.trackpadVerticalGain > 1
        trackpadGainIncreaseButton.isEnabled = preferences.trackpadVerticalGain < 5
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

    /// Changes only mouse gain by 0.1 in the clicked button's direction. The
    /// preference setter clamps and rounds the result; refresh updates the
    /// settings editor and disables whichever direction has reached its bound.
    @objc private func changeMouseGainFromMenu(_ sender: NSButton) {
        preferences.mouseVerticalGain += Double(sender.tag) * 0.1
        applyPreferences()
    }

    /// Changes only trackpad gain by the left/right button's signed 0.1 step.
    /// Saving preserves the existing range and hundredth precision, and refresh
    /// keeps both surfaces current without altering the mouse value or switches.
    @objc private func changeTrackpadGainFromMenu(_ sender: NSButton) {
        preferences.trackpadVerticalGain += Double(sender.tag) * 0.1
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
