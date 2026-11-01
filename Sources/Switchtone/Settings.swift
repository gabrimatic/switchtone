import Foundation
import Synchronization

/// The values the event-tap thread reads on every keystroke, as atomics.
final class LiveSettings: Sendable {
    private let enabled = Atomic<Bool>(true)
    private let focusMuted = Atomic<Bool>(false)
    private let muteSecure = Atomic<Bool>(true)
    private let trackpadTick = Atomic<Bool>(true)
    private let volumeBits = Atomic<UInt32>(Float(0.6).bitPattern)

    var gate: KeyListener.Gate {
        // A silent volume skips the strike altogether: no output to wake, nothing to hold.
        KeyListener.Gate(enabled: enabled.load(ordering: .relaxed) && !focusMuted.load(ordering: .relaxed)
                             && volume > AppModel.silentVolume,
                         muteSecure: muteSecure.load(ordering: .relaxed))
    }

    var volume: Float { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
    var tickEnabled: Bool { trackpadTick.load(ordering: .relaxed) }

    func set(enabled value: Bool) { enabled.store(value, ordering: .relaxed) }
    func set(focusMuted value: Bool) { focusMuted.store(value, ordering: .relaxed) }
    func set(muteSecure value: Bool) { muteSecure.store(value, ordering: .relaxed) }
    func set(volume value: Float) { volumeBits.store(value.bitPattern, ordering: .relaxed) }
    func set(trackpadTick value: Bool) { trackpadTick.store(value, ordering: .relaxed) }
}

/// User settings in UserDefaults. Main actor; the tap thread reads `live`.
@MainActor
final class Settings {
    enum Keys {
        static let enabled = "enabled"
        static let profile = "profile"
        static let volume = "volume"
        static let muteSecure = "muteWhenTypingPasswords"
        static let loginConfigured = "loginConfigured"
        static let spatial = "spatial"
        static let headTracking = "headTracking"
        static let focusMuted = "focusMuted"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let trackpadTick = "trackpadTick"
        static let askedForAccess = "askedForInputMonitoring"
        static let silentTapRelaunchAt = "silentTapRelaunchAt"
        static let onboardingCompleted = "onboardingCompleted"
    }

    let live = LiveSettings()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        repair()
    }

    /// The keys the app watches for writes from outside (`defaults write`, a script, another tool).
    static let watchedKeys = [Keys.enabled, Keys.profile, Keys.volume, Keys.muteSecure, Keys.spatial, Keys.headTracking, Keys.focusMuted, Keys.showMenuBarIcon, Keys.trackpadTick]

    private static let initial: [String: Any] = [
        Keys.enabled: true,
        Keys.profile: Profile.tactile.rawValue,
        Keys.volume: 0.6,
        Keys.muteSecure: true,
        Keys.spatial: true,
        Keys.headTracking: true,
        Keys.focusMuted: false,
        Keys.showMenuBarIcon: true,
        Keys.trackpadTick: true,
    ]

    /// The store the settings live in.
    var store: UserDefaults { defaults }

    /// Makes the store hold a valid value for every setting, writing only what is missing or out of
    /// range, and brings the tap thread's copy in line with it. Runs at launch and after every write
    /// from outside, so `defaults read` always shows the state the app is really in.
    /// Returns the keys it had to write.
    @discardableResult
    func repair() -> [String] {
        var written: [String] = []
        for (key, value) in Self.initial where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            written.append(key)
        }
        if Profile(rawValue: defaults.string(forKey: Keys.profile) ?? "") == nil {
            defaults.set(Profile.tactile.rawValue, forKey: Keys.profile)
            written.append(Keys.profile)
        }
        let raw = (defaults.object(forKey: Keys.volume) as? NSNumber)?.doubleValue ?? .nan
        if !(0...1).contains(raw) {
            defaults.set(raw.isFinite ? min(1, max(0, raw)) : 0.6, forKey: Keys.volume)
            written.append(Keys.volume)
        }
        refreshLive()
        return written
    }

    /// Copies the stored values into the atomics the event-tap thread reads.
    func refreshLive() {
        live.set(enabled: enabled)
        live.set(focusMuted: focusMuted)
        live.set(muteSecure: muteSecure)
        live.set(volume: volume)
        live.set(trackpadTick: trackpadTick)
    }

    var enabled: Bool {
        get { defaults.object(forKey: Keys.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.enabled); live.set(enabled: newValue) }
    }

    /// Whether the menu bar icon is shown. On for a new install; with it off, everything stays in Settings.
    var showMenuBarIcon: Bool {
        get { defaults.object(forKey: Keys.showMenuBarIcon) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showMenuBarIcon) }
    }

    /// A trackpad tick with each key press. On by default, where the Mac has the hardware for it.
    var trackpadTick: Bool {
        get { defaults.object(forKey: Keys.trackpadTick) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.trackpadTick); live.set(trackpadTick: newValue) }
    }

    var focusMuted: Bool {
        get { defaults.bool(forKey: Keys.focusMuted) }
        set { defaults.set(newValue, forKey: Keys.focusMuted); live.set(focusMuted: newValue) }
    }

    var muteSecure: Bool {
        get { defaults.object(forKey: Keys.muteSecure) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.muteSecure); live.set(muteSecure: newValue) }
    }

    var volume: Float {
        get {
            guard let number = defaults.object(forKey: Keys.volume) as? NSNumber, number.doubleValue.isFinite else { return 0.6 }
            return Float(min(1, max(0, number.doubleValue)))
        }
        set {
            let clamped = min(1, max(0, newValue.isFinite ? newValue : 0.6))
            defaults.set(Double(clamped), forKey: Keys.volume)
            live.set(volume: clamped)
        }
    }

    var profile: Profile {
        get { Profile(rawValue: defaults.string(forKey: Keys.profile) ?? "") ?? .tactile }
        set { defaults.set(newValue.rawValue, forKey: Keys.profile) }
    }

    var spatial: Bool {
        get { defaults.object(forKey: Keys.spatial) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.spatial) }
    }

    var headTracking: Bool {
        get { defaults.object(forKey: Keys.headTracking) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.headTracking) }
    }

    /// Whether Switchtone has already used the system's Input Monitoring prompt, which macOS shows once.
    /// The welcome window (or the first need for it) asks; after that the panel and Settings explain it.
    var askedForAccess: Bool {
        get { defaults.bool(forKey: Keys.askedForAccess) }
        set { defaults.set(newValue, forKey: Keys.askedForAccess) }
    }

    /// Whether the welcome window still has to be shown: until it closes, and again after "Show Again".
    var onboardingNeeded: Bool { !defaults.bool(forKey: Keys.onboardingCompleted) }

    func setOnboardingCompleted(_ done: Bool) { defaults.set(done, forKey: Keys.onboardingCompleted) }

    /// When Switchtone last relaunched itself because its event tap heard nothing.
    var silentTapRelaunchAt: Date? {
        get { defaults.object(forKey: Keys.silentTapRelaunchAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.silentTapRelaunchAt) }
    }

    var loginConfigured: Bool {
        get { defaults.bool(forKey: Keys.loginConfigured) }
        set { defaults.set(newValue, forKey: Keys.loginConfigured) }
    }
}


/// Reports writes to the settings keys from anywhere, this process included (key-value observing on
/// `UserDefaults` is the mechanism the system documents for changes made by another process). The
/// callback runs on whatever thread the write happened on and must hop to the main thread itself.
final class DefaultsObserver: NSObject, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keys: [String]
    private let onChange: @Sendable () -> Void

    init(defaults: UserDefaults, keys: [String], onChange: @escaping @Sendable () -> Void) {
        self.defaults = defaults
        self.keys = keys
        self.onChange = onChange
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        onChange()
    }

    func invalidate() {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }
}
