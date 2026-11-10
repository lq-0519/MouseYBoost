import ServiceManagement

/// Uses macOS's native per-user login item. No LaunchAgent, helper process,
/// periodically running job, or duplicate preference flag is installed.
enum LoginItem {
    /// Actual system registration status, including pending user approval.
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    /// Checkbox reflects enabled or registered-but-awaiting-approval states.
    static var registered: Bool {
        status == .enabled || status == .requiresApproval
    }
    /// Chinese explanation of the system-owned login item state.
    static var statusText: String {
        switch status {
        case .enabled: return "登录后在菜单栏运行"
        case .requiresApproval: return "已申请自启动，请在系统登录项中允许"
        case .notRegistered: return "不会在登录时自动启动"
        case .notFound: return "自启动尚未就绪，可勾选重新设置"
        @unknown default: return "请在系统登录项中查看状态"
        }
    }

    /// Registers or unregisters the fixed installed application bundle.
    /// Errors are displayed to the user and the checkbox is restored from macOS.
    static func setEnabled(_ enabled: Bool) throws {
        guard Bundle.main.bundlePath == "/Applications/MouseYBoost.app" else {
            throw NSError(domain: "MouseYBoost", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请从固定安装路径 /Applications/MouseYBoost.app 启动。",
            ])
        }
        if enabled {
            if status != .enabled && status != .requiresApproval {
                try SMAppService.mainApp.register()
            }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
