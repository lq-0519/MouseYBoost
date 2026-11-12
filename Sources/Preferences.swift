import Foundation

/// Small persistent preference store. UI access stays on the main thread;
/// the event worker receives immutable snapshots rather than reading defaults.
final class Preferences {
    /// Stable defaults namespace follows the installed bundle identifier.
    private let defaults = UserDefaults.standard
    /// Independent Logitech mouse switch. Reuses the original defaults key so
    /// upgrading preserves the user's saved mouse setting without migration.
    var mouseEnabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    /// Independent trackpad switch, disabled on first use and after upgrading
    /// unless explicitly enabled. It never depends on the mouse switch.
    var trackpadEnabled: Bool {
        get { defaults.bool(forKey: "trackpadEnabled") }
        set { defaults.set(newValue, forKey: "trackpadEnabled") }
    }
    /// Independent mouse multiplier. Existing installations inherit the former
    /// shared value once; subsequent edits never change the trackpad multiplier.
    var mouseVerticalGain: Double {
        get { Self.normalizedGain(defaults.double(forKey: "mouseVerticalGain")) }
        set { defaults.set(Self.normalizedGain(newValue), forKey: "mouseVerticalGain") }
    }
    /// Independent trackpad multiplier, retained even while its switch is off.
    /// One means this device passes through without any additional displacement.
    var trackpadVerticalGain: Double {
        get { Self.normalizedGain(defaults.double(forKey: "trackpadVerticalGain")) }
        set { defaults.set(Self.normalizedGain(newValue), forKey: "trackpadVerticalGain") }
    }
    /// Records whether first-run settings have been displayed.
    var hasLaunched: Bool {
        get { defaults.bool(forKey: "hasLaunched") }
        set { defaults.set(newValue, forKey: "hasLaunched") }
    }

    /// Registers switch defaults and copies the legacy shared multiplier into
    /// each missing device-specific key. Persisting both copies makes migration
    /// run once without replacing any independently saved multiplier or switch.
    init() {
        defaults.register(defaults: [
            "enabled": true,
            "trackpadEnabled": false,
            "hasLaunched": false,
        ])
        let legacyGain = Self.normalizedGain(defaults.object(forKey: "verticalGain") as? Double ?? 1.3)
        for key in ["mouseVerticalGain", "trackpadVerticalGain"] {
            if defaults.object(forKey: key) == nil {
                defaults.set(legacyGain, forKey: key)
            }
        }
    }

    /// Applies the same finite 1–5 range and hundredth precision to every input
    /// path, including menu arrows, numeric edits, sliders, and legacy migration.
    private static func normalizedGain(_ value: Double) -> Double {
        guard value.isFinite else { return 1.3 }
        return (min(5, max(1, value)) * 100).rounded() / 100
    }
}
