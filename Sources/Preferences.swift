import Foundation

/// Small persistent preference store. UI access stays on the main thread;
/// the event worker receives immutable snapshots rather than reading defaults.
final class Preferences {
    /// Stable defaults namespace follows the installed bundle identifier.
    private let defaults = UserDefaults.standard
    /// Persistent master switch; disabling it destroys the active event tap.
    var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// Vertical speed multiplier. One means pass-through with no event worker.
    var verticalGain: Double {
        get {
            let value = defaults.double(forKey: "verticalGain")
            return value.isFinite ? min(5, max(1, value)) : 1.3
        }
        set { defaults.set(min(5, max(1, newValue)), forKey: "verticalGain") }
    }
    /// Records whether first-run settings have been displayed.
    var hasLaunched: Bool {
        get { defaults.bool(forKey: "hasLaunched") }
        set { defaults.set(newValue, forKey: "hasLaunched") }
    }

    /// Registers defaults in memory; it does not overwrite saved user choices.
    init() {
        defaults.register(defaults: [
            "enabled": true,
            "verticalGain": 1.3,
            "hasLaunched": false,
        ])
    }
}
