import AppKit
import ApplicationServices
import ServiceManagement

/// Native settings window, created once on demand and refreshed only on events.
final class SettingsWindow: NSWindowController, NSTextFieldDelegate {
    /// UI-owned preferences store supplied by the application delegate.
    private let preferences: Preferences
    /// Applies an enabled/gain change to the running engine immediately.
    var onPreferencesChanged: (() -> Void)?
    /// Explicit refresh lets users apply a newly granted permission without restarting.
    var onRefreshRequested: (() -> Void)?
    /// Master switch remains available from the window and the menu bar.
    private let enabledButton = NSButton(checkboxWithTitle: "启用纵向速度增益",
                                         target: nil, action: nil)
    /// Continuous slider covers common gains without editing numeric text.
    private let gainSlider = NSSlider(value: 1.3, minValue: 1, maxValue: 5,
                                       target: nil, action: nil)
    /// Editable multiplier accepts values between one and five.
    private let gainField = NSTextField(string: "")
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
        window.title = "MouseYBoost · 鼠标纵向增益"
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
        enabledButton.state = preferences.enabled ? .on : .off
        gainSlider.doubleValue = preferences.verticalGain
        if gainField.currentEditor() == nil {
            gainField.stringValue = String(format: "%.2f", preferences.verticalGain)
        }
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
            : "首次使用需要允许 MouseYBoost 调整鼠标事件。"
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
        let subtitle = note("为罗技外接鼠标放大纵向移动。横向、滚轮和触控板保持原有行为。")
        stack.addArrangedSubview(subtitle)
        enabledButton.target = self
        enabledButton.action = #selector(toggleEnabled)
        stack.addArrangedSubview(enabledButton)
        stateLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(stateLabel)
        stack.addArrangedSubview(separator())

        let gainTitle = NSTextField(labelWithString: "纵向速度倍数")
        gainTitle.font = .systemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(gainTitle)
        gainSlider.target = self
        gainSlider.action = #selector(sliderChanged)
        gainSlider.isContinuous = false
        gainSlider.widthAnchor.constraint(equalToConstant: 340).isActive = true
        gainField.delegate = self
        gainField.alignment = .right
        gainField.widthAnchor.constraint(equalToConstant: 68).isActive = true
        gainField.target = self
        gainField.action = #selector(numberChanged)
        let gainRow = NSStackView(views: [gainSlider, gainField,
                                        NSTextField(labelWithString: "倍")])
        gainRow.spacing = 12
        stack.addArrangedSubview(gainRow)
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
        stack.addArrangedSubview(note("菜单栏常驻 · 无定时轮询 · 关闭或 1 倍时停止监听"))
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

    /// Persists the master switch and starts/stops the event engine.
    @objc private func toggleEnabled() {
        preferences.enabled = enabledButton.state == .on
        onPreferencesChanged?()
    }

    /// Applies the final slider value once it is released, avoiding tap churn.
    @objc private func sliderChanged() {
        preferences.verticalGain = (gainSlider.doubleValue * 100).rounded() / 100
        gainField.stringValue = String(format: "%.2f", preferences.verticalGain)
        onPreferencesChanged?()
    }

    /// Validates an entered multiplier and restores the saved value if invalid.
    @objc private func numberChanged() {
        let text = gainField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value.isFinite, (1...5).contains(value) else {
            gainField.stringValue = String(format: "%.2f", preferences.verticalGain)
            NSSound.beep()
            return
        }
        preferences.verticalGain = (value * 100).rounded() / 100
        gainField.stringValue = String(format: "%.2f", preferences.verticalGain)
        gainSlider.doubleValue = preferences.verticalGain
        onPreferencesChanged?()
    }

    /// Commits a numeric edit when focus leaves the field as well as on Return.
    func controlTextDidEndEditing(_ obj: Notification) { numberChanged() }

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
