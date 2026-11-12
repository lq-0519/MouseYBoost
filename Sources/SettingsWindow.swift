import AppKit
import ApplicationServices
import ServiceManagement

/// Native settings window, created once on demand and refreshed only on events.
final class SettingsWindow: NSWindowController {
    /// UI-owned preferences store supplied by the application delegate.
    private let preferences: Preferences
    /// Applies either device's independent switch or multiplier immediately.
    var onPreferencesChanged: (() -> Void)?
    /// Explicit refresh lets users apply a newly granted permission without restarting.
    var onRefreshRequested: (() -> Void)?
    /// Independent mouse switch mirrors the menu and preserves the old setting.
    private let mouseEnabledButton = NSButton(checkboxWithTitle: "启用鼠标纵向增益",
                                              target: nil, action: nil)
    /// Independent trackpad switch starts unchecked and remains usable when
    /// mouse gain is off, retaining its own stored multiplier between changes.
    private let trackpadEnabledButton = NSButton(checkboxWithTitle: "启用触控板纵向增益",
                                                 target: nil, action: nil)
    /// Mouse-only slider and numeric editor share synchronization behavior with
    /// the trackpad row but read and write an independent saved multiplier.
    private let mouseGainControls = GainControls(name: "鼠标纵向增益")
    /// Trackpad-only slider and numeric editor stay configurable while disabled.
    private let trackpadGainControls = GainControls(name: "触控板纵向增益")
    /// Actual system registration controls the autostart checkbox.
    private let loginButton = NSButton(checkboxWithTitle: "登录时自动启动",
                                       target: nil, action: nil)
    /// Sparse runtime status indicates whether input is actually being processed.
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    /// Shows accessibility permission without a background polling timer.
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    /// Login item message is read from SMAppService, not a saved bool.
    private let loginLabel = NSTextField(wrappingLabelWithString: "")
    /// Permission action opens the appropriate macOS settings pane.
    private let permissionButton = NSButton(title: "开启辅助功能权限",
                                            target: nil, action: nil)
    /// Pending login item approval can be completed in System Settings.
    private let loginSettingsButton = NSButton(title: "系统登录项…",
                                               target: nil, action: nil)

    /// Builds the complete settings surface with standard AppKit controls.
    init(preferences: Preferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 485),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "MouseYBoost · 指针纵向增益"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }

    /// Storyboard construction is unsupported because the app is built without one.
    required init?(coder: NSCoder) { fatalError("Use init(preferences:)") }

    /// Opens and focuses settings; the caller refreshes permission on this event.
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Reflects stored settings and actual OS state without saving anything.
    func refresh(state: EngineState, trusted: Bool) {
        mouseEnabledButton.state = preferences.mouseEnabled ? .on : .off
        trackpadEnabledButton.state = preferences.trackpadEnabled ? .on : .off
        mouseGainControls.refresh(value: preferences.mouseVerticalGain)
        trackpadGainControls.refresh(value: preferences.trackpadVerticalGain)
        stateLabel.stringValue = state.text
        stateLabel.textColor = {
            switch state {
            case .permissionRequired, .failure: return .systemOrange
            case .active: return .systemGreen
            default: return .secondaryLabelColor
            }
        }()
        permissionLabel.stringValue = trusted
            ? "辅助功能权限已开启"
            : "首次使用需要允许 MouseYBoost 调整指针事件。"
        permissionButton.title = trusted ? "辅助功能设置…" : "开启辅助功能权限"
        loginButton.state = LoginItem.registered ? .on : .off
        loginLabel.stringValue = LoginItem.statusText
        loginSettingsButton.isHidden = LoginItem.status != .requiresApproval
    }

    /// Constructs a vertically arranged native layout with no web view or animation.
    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        let title = NSTextField(labelWithString: "上下移动，更省手腕")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        stack.addArrangedSubview(title)
        let subtitle = note("分别配置罗技鼠标和触控板的开关与纵向增益倍数。")
        stack.addArrangedSubview(subtitle)
        stateLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(stateLabel)
        stack.addArrangedSubview(separator())

        mouseEnabledButton.target = self
        mouseEnabledButton.action = #selector(toggleMouseEnabled)
        stack.addArrangedSubview(mouseEnabledButton)
        mouseGainControls.onValueChanged = { [weak self] value in
            self?.preferences.mouseVerticalGain = value
            self?.onPreferencesChanged?()
        }
        stack.addArrangedSubview(mouseGainControls)
        trackpadEnabledButton.target = self
        trackpadEnabledButton.action = #selector(toggleTrackpadEnabled)
        stack.addArrangedSubview(trackpadEnabledButton)
        trackpadGainControls.onValueChanged = { [weak self] value in
            self?.preferences.trackpadVerticalGain = value
            self?.onPreferencesChanged?()
        }
        stack.addArrangedSubview(trackpadGainControls)
        stack.addArrangedSubview(note("1 倍为原速；建议从 1.2～1.5 倍开始。范围：1～5 倍。"))
        stack.addArrangedSubview(separator())

        loginButton.target = self
        loginButton.action = #selector(toggleLogin)
        stack.addArrangedSubview(loginButton)
        loginLabel.font = .systemFont(ofSize: 12)
        loginLabel.textColor = .secondaryLabelColor
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings)
        let loginRow = NSStackView(views: [loginLabel, loginSettingsButton])
        loginRow.spacing = 12
        stack.addArrangedSubview(loginRow)
        stack.addArrangedSubview(separator())

        permissionLabel.font = .systemFont(ofSize: 12)
        permissionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(permissionLabel)
        permissionButton.target = self
        permissionButton.action = #selector(openAccessibility)
        let refreshButton = NSButton(title: "重新检查权限", target: self,
                                     action: #selector(refreshPermission))
        let permissionRow = NSStackView(views: [permissionButton, refreshButton])
        permissionRow.spacing = 12
        stack.addArrangedSubview(permissionRow)
        stack.addArrangedSubview(note("菜单栏常驻 · 没有设备需要增益时停止监听"))
        // Fit every native control at its intrinsic height, including longer
        // device/status labels, rather than compressing content into a fixed size.
        window?.setContentSize(NSSize(width: 560, height: stack.fittingSize.height.rounded(.up) + 44))
    }

    /// Makes a subdued wrapping label for short explanations.
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 504
        return label
    }

    /// Creates a full-width visual divider within the settings stack.
    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 504).isActive = true
        return box
    }

    /// Saves only mouse eligibility; an enabled trackpad keeps its gain active.
    @objc private func toggleMouseEnabled() {
        preferences.mouseEnabled = mouseEnabledButton.state == .on
        onPreferencesChanged?()
    }

    /// Saves only trackpad eligibility and immediately reapplies its own gain.
    /// Turning it off never changes the mouse switch or the saved multiplier.
    @objc private func toggleTrackpadEnabled() {
        preferences.trackpadEnabled = trackpadEnabledButton.state == .on
        onPreferencesChanged?()
    }

    /// Updates the real macOS login item and displays registration errors.
    @objc private func toggleLogin() {
        do {
            try LoginItem.setEnabled(loginButton.state == .on)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法更新自启动设置"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
        onRefreshRequested?()
    }

    /// Opens the macOS accessibility pane; the user grants permission there.
    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Checks permission explicitly after the user changes System Settings.
    @objc private func refreshPermission() { onRefreshRequested?() }

    /// Opens native login item settings when registration needs user approval.
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// One device's native gain row. Both rows use this editor so menu-originated
/// changes update active field editors consistently without coupling their values.
private final class GainControls: NSStackView, NSTextFieldDelegate {
    /// Delivers a validated, rounded value to the owning settings controller,
    /// which persists the corresponding device setting before refreshing both UIs.
    var onValueChanged: ((Double) -> Void)?
    /// Slider commits only on release so moving it does not repeatedly restart
    /// the input worker before the user finishes choosing a multiplier.
    private let slider = NSSlider(value: 1.3, minValue: 1, maxValue: 5,
                                   target: nil, action: nil)
    /// Numeric input accepts hundredths in the same 1–5 range as the slider.
    private let field = NSTextField(string: "1.30")
    /// Last persisted value distinguishes a real external change from an
    /// unrelated status refresh while the user is still composing numeric text.
    private var savedValue = 1.3

    /// Builds an independently labeled row with identical numeric validation
    /// and synchronization behavior for either mouse or trackpad preferences.
    init(name: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 12
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = false
        slider.setAccessibilityLabel(name + "倍数")
        slider.widthAnchor.constraint(equalToConstant: 340).isActive = true
        field.delegate = self
        field.alignment = .right
        field.target = self
        field.action = #selector(numberChanged)
        field.setAccessibilityLabel(name + "倍数")
        field.widthAnchor.constraint(equalToConstant: 68).isActive = true
        addArrangedSubview(slider)
        addArrangedSubview(field)
        addArrangedSubview(NSTextField(labelWithString: "倍"))
    }

    /// Storyboards are unsupported; each row requires an explicit device label.
    required init?(coder: NSCoder) { fatalError("Use init(name:)") }

    /// Reflects persisted changes even when the numeric field still owns focus.
    /// Unchanged values preserve in-progress typing during sparse engine updates;
    /// changed values replace the editor text to prevent stale text being saved.
    func refresh(value: Double) {
        let changed = savedValue != value
        savedValue = value
        slider.doubleValue = value
        if changed || field.currentEditor() == nil {
            showValue(value)
        }
    }

    /// Updates both the control's stored text and AppKit's live field editor.
    /// Updating only stringValue can leave an active editor displaying old text,
    /// which would otherwise overwrite a newer menu value when editing ends.
    private func showValue(_ value: Double) {
        slider.doubleValue = value
        let text = String(format: "%.2f", value)
        field.stringValue = text
        if let editor = field.currentEditor() {
            editor.string = text
            editor.selectAll(nil)
        }
    }

    /// Commits a released slider value with hundredth precision and immediately
    /// replaces any numeric draft with the same formatted value before saving.
    @objc private func sliderChanged() {
        let value = (slider.doubleValue * 100).rounded() / 100
        showValue(value)
        onValueChanged?(value)
    }

    /// Validates live editor text on Return or focus loss. Invalid text restores
    /// the latest persisted value, including changes made through the menu.
    @objc private func numberChanged() {
        let text = (field.currentEditor()?.string ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite, (1...5).contains(value) else {
            showValue(savedValue)
            NSSound.beep()
            return
        }
        let rounded = (value * 100).rounded() / 100
        showValue(rounded)
        onValueChanged?(rounded)
    }

    /// Applies the same validation when focus leaves as when Return is pressed.
    func controlTextDidEndEditing(_ obj: Notification) { numberChanged() }
}
