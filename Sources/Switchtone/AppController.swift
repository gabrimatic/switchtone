import AppKit
import Carbon.HIToolbox
import Darwin
import WidgetKit
import ServiceManagement
import os

/// Owns the settings, the sound engine and the key listener, and turns panel,
/// shortcut, intent and system events into state changes.
@MainActor
final class AppController {
    /// The running app's controller, for App Intents (they run in this process).
    static var shared: AppController?

    let model = AppModel()
    let settings: Settings
    private let sound: SoundEngine
    /// Where the Sounds folder lives (the app bundle).
    private let resources: URL?
    private var listener: KeyListener!
    /// The trackpad tick, once the capability check has found an actuator. Read by the tap thread.
    private let tick = TickHolder()
    private let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "app")
    private var permissionTimer: Timer?
    private var silentTapTimer: Timer?
    private var grantedResetTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Preview banks, decoded off the main thread and kept while the panel is open.
    private var previewLoads: [Profile: Task<SoundBank?, Never>] = [:]
    /// Bumped by every profile choice; a decode that finishes after a newer choice is dropped.
    private var loadGeneration = 0
    private var wakeObserver: NSObjectProtocol?
    private var returnObservers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?
    /// Watches the settings keys for writes from outside the app (`defaults write`, scripts).
    private var settingsObserver: DefaultsObserver?
    private var permissionInterval: TimeInterval = 0
    /// A grant check is in flight (they take about 10 ms, so they run off the main thread).
    private var probingGrant = false
    /// A silent tap that a relaunch did not cure: the grant belongs to another copy.
    private var silentAfterRelaunch = false
    /// Set when System Settings comes to the front while the grant is stale.
    private var visitedSettings = false
    private var loggedSecureInput = false
    /// How the panel reads the login item's status when it opens.
    var loginProbe: (@Sendable () -> SMAppService.Status)? = { LoginItem.status }
    /// Called when the status icon should redraw.
    var onStateChange: (() -> Void)?
    /// Called when "Show menu bar icon" changes, from Settings or from outside the app.
    var onMenuBarIconChange: (() -> Void)?
    /// Asks the app to show the welcome window (after "Show Again").
    var onShowOnboarding: (() -> Void)?
    /// Asks the app to show the Settings window (the panel's gear button).
    var onShowSettings: (() -> Void)?
    /// While a window is open, the grant is looked at once a second, so its status turns green at once.
    private var windowTimer: Timer?

    /// Opens Privacy & Security at the Input Monitoring list.
    static let inputMonitoringURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")

    init(settings: Settings = Settings(), sound: SoundEngine = SoundEngine(), resources: URL? = Bundle.main.resourceURL) {
        self.settings = settings
        self.resources = resources
        self.sound = sound
        model.controller = self
        let live = settings.live
        let sound = sound
        listener = KeyListener(
            gate: { live.gate },
            onStrike: { [tick] strike in
                // Ahead of the sound: the tick needs no audio cycle, and it costs this thread a flag.
                if strike.down, live.tickEnabled { tick.fire() }
                sound.play(strike, volume: live.volume)   // the gate already skips a silent volume
            },
            onShortcut: { [weak self] in Task { @MainActor in self?.toggleEnabled() } },
            // A click inside a typing session means the next key is close: start the output now, so
            // it is ready by then. Free when it already runs (one atomic load); after a quiet spell
            // or in Low Power Mode a click does nothing, the first key restarts the output itself.
            onActivity: { if live.gate.enabled { sound.warmForClick() } },
            onRevoked: { [weak self] in
                // macOS switched the tap off; give it a moment, then see whether the permission is gone.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.checkTapHealth()
                }
            }
        )
        // The counters are written whenever the output pauses (and on a panel open and at quit), so
        // they can be read live without quitting Switchtone.
        sound.onPaused = { [weak self] reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log.notice("output paused (\(reason, privacy: .public)): \(self.diagnostics, privacy: .public)")
            }
        }
        sound.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                guard let self, self.model.engine != status else { return }
                self.model.engine = status
                self.onStateChange?()
            }
        }
    }

    // MARK: Launch

    func launch() {
        model.enabled = settings.enabled
        model.profile = settings.profile
        model.volume = settings.volume
        model.spatial = settings.spatial
        model.headTracking = settings.headTracking
        model.muteSecure = settings.muteSecure
        model.focusMuted = settings.focusMuted
        model.showMenuBarIcon = settings.showMenuBarIcon
        model.trackpadTick = settings.trackpadTick
        prepareTick()

        // A first launch shows the welcome window, whose button asks for Input Monitoring through the
        // system prompt (so macOS lists Switchtone and the user only flips a switch). Later launches
        // never pop a dialog; the panel and the menu bar symbol show what is missing.
        model.onboardingPending = settings.onboardingNeeded
        model.accessRequested = settings.askedForAccess
        model.returningInstall = settings.askedForAccess
        if !settings.loginConfigured {
            if let error = LoginItem.set(true) { log.error("login item registration failed: \(error, privacy: .public)") }
            settings.loginConfigured = true
        }
        refreshLogin()
        log.info("login item: \(LoginItem.statusDescription, privacy: .public)")
        publishSharedState()
        observeSettings()

        loadProfile(settings.profile)
        sound.configure(spatial: settings.spatial, headTracking: settings.headTracking)
        startListening()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkTapHealth()
                self?.sound.recoverAfterWake()
                self?.warmForReturn()
            }
        }
        // Coming back to the Mac (screen wake, unlock, fast user switch): start the
        // output now, so the first key finds it running instead of waking it.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            returnObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmForReturn() }
            })
        }
        // Switching apps is when a grant usually lands (leaving System
        // Settings), so the permission is re-checked then instead of by a fast poll.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.applicationActivated(bundleID) }
        }
    }

    /// The defaults domain is the settings store (SPEC 6.5), so a write from outside the app, such as
    /// `defaults write` or a script, is adopted live: the panel, the sounds and the tap follow it, and
    /// `defaults read` never disagrees with what the app shows. The app's own writes arrive here too and
    /// change nothing, because the model already holds the value.
    private func observeSettings() {
        settingsObserver?.invalidate()
        settingsObserver = DefaultsObserver(defaults: settings.store, keys: Settings.watchedKeys) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.settingsChangedOutside() } }
        }
    }

    func settingsChangedOutside() {
        let repaired = settings.repair()
        if !repaired.isEmpty { log.notice("settings: restored \(repaired.sorted().joined(separator: ", "), privacy: .public)") }
        var adopted: [String] = []
        if settings.enabled != model.enabled {
            model.enabled = settings.enabled
            if model.enabled { if model.audible { sound.warmUp() } } else { sound.stop() }
            publishSharedState()
            adopted.append("enabled")
        }
        if settings.focusMuted != model.focusMuted {
            model.focusMuted = settings.focusMuted
            if model.focusMuted { sound.stop() } else if model.audible { sound.warmUp() }
            adopted.append("focusMuted")
        }
        if settings.profile != model.profile {
            model.profile = settings.profile
            loadProfile(settings.profile)
            adopted.append("profile")
        }
        if settings.volume != model.volume {
            let wasMuted = model.volumeMuted
            model.volume = settings.volume
            if model.volumeMuted != wasMuted {
                if model.volumeMuted { sound.stop() } else if model.audible { sound.warmUp() }
            }
            adopted.append("volume")
        }
        if settings.muteSecure != model.muteSecure {
            model.muteSecure = settings.muteSecure
            adopted.append("muteWhenTypingPasswords")
        }
        let spatialChanged = settings.spatial != model.spatial, headChanged = settings.headTracking != model.headTracking
        if spatialChanged || headChanged {
            model.spatial = settings.spatial
            model.headTracking = settings.headTracking
            sound.configure(spatial: settings.spatial, headTracking: settings.headTracking)
            if spatialChanged { adopted.append("spatial") }
            if headChanged { adopted.append("headTracking") }
        }
        if settings.trackpadTick != model.trackpadTick {
            model.trackpadTick = settings.trackpadTick
            adopted.append("trackpadTick")
        }
        if settings.showMenuBarIcon != model.showMenuBarIcon {
            model.showMenuBarIcon = settings.showMenuBarIcon
            log.notice("settings changed outside the app, adopted: showMenuBarIcon")
            onMenuBarIconChange?()
        }
        guard !adopted.isEmpty else { return }
        log.notice("settings changed outside the app, adopted: \(adopted.joined(separator: ", "), privacy: .public)")
        onStateChange?()
    }

    /// The capability check talks to the trackpad's driver, so it runs off the main thread. Without an
    /// actuator the feature is simply absent, and Settings says what it would need.
    private func prepareTick() {
        let holder = tick
        Task.detached(priority: .utility) { [weak self] in
            let actuator = MultitouchActuator.make()
            if let actuator { holder.install(TrackpadTick(actuator: actuator)) }
            let available = actuator != nil
            await MainActor.run {
                self?.model.tickAvailable = available
                self?.log.notice("trackpad tick: \(available ? "ready" : "no actuator", privacy: .public)")
            }
        }
    }

    private func warmForReturn() {
        if model.audible { sound.warmUp() }
    }

    private func applicationActivated(_ bundleID: String?) {
        if silentAfterRelaunch {
            if bundleID == PermissionWatch.settingsBundleID {
                visitedSettings = true
            } else if visitedSettings {
                // Back from System Settings, where the user switched Switchtone off
                // and on: only a fresh process picks up the new grant.
                visitedSettings = false
                log.notice("input monitoring: re-checking with a fresh process after System Settings")
                relaunch()
            }
            return
        }
        guard model.permission != .granted else { return }
        retryListening()
        if model.permission != .granted { watchForGrant() }
    }

    /// Decodes the bank on a background task, then swaps it in on the main
    /// actor. The main thread never waits for the decode, so the selection
    /// animation in the panel keeps its frames. The latest choice wins.
    private func loadProfile(_ profile: Profile) {
        loadGeneration &+= 1
        let generation = loadGeneration
        let resources = self.resources
        Task.detached(priority: .userInitiated) { [weak self] in
            // The decode's temporary files and buffers are autoreleased: drain
            // them, then give their pages back before the result goes to the main actor.
            let result = autoreleasepool { Result { () throws(SoundBank.LoadError) in try SoundBank.load(profile, from: resources) } }
            Self.returnFreedMemory()
            await self?.bankLoaded(result, profile: profile, generation: generation)
        }
    }

    private func bankLoaded(_ result: Result<SoundBank, SoundBank.LoadError>, profile: Profile, generation: Int) {
        guard generation == loadGeneration else { return }
        switch result {
        case .success(let bank):
            sound.setBank(bank)
            model.profileProblem = nil
        case .failure(let error):
            model.profileProblem = error.message
            log.error("profile \(profile.rawValue, privacy: .public) failed to load")
        }
        onStateChange?()
    }

    // MARK: Input Monitoring

    /// macOS hands out a working tap handle even without the permission and
    /// then silently delivers no key events, so the preflight is the real gate.
    /// The preflight takes about 10 ms, so it is asked off the main thread and
    /// the result is applied back here.
    private func startListening() {
        Task { @MainActor [weak self] in
            let allowed = await InputAccess.preflight()
            self?.applyListening(preflight: allowed)
        }
    }

    private func applyListening(preflight allowed: Bool) {
        if allowed, listener.start() {
            permissionGranted()
        } else {
            model.permission = allowed ? .stale : .missing
            log.notice("input monitoring: \(self.model.permission == .stale ? "stale" : "missing", privacy: .public); watching for the grant")
            watchForGrant()
        }
        onStateChange?()
    }

    private func permissionGranted() {
        let wasWaiting = model.permission != .granted
        model.permission = .granted
        model.waitingForGrant = false
        stopWatchingForGrant()
        if model.audible { sound.warmUp() }
        log.notice("input monitoring: granted, listening")
        if wasWaiting {
            model.justGranted = true
            Haptics.perform(.levelChange)
            grantedResetTask?.cancel()
            grantedResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.model.justGranted = false
            }
        }
        // Also at launch: a tap macOS accepts can still be deaf when the grant
        // in the list belongs to another copy.
        watchForSilentTap()
        onStateChange?()
    }

    /// Checks for the grant: there is no notification for it. Every second
    /// while System Settings is in front (the user is flipping the switch),
    /// otherwise when any app activates plus a slow safety check.
    private func watchForGrant() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // With a Switchtone window open its own once-a-second timer reads the grant (see `windowsChanged`).
        guard windowTimer == nil else { return }
        let interval = PermissionWatch.interval(frontmost: frontmost)
        guard permissionTimer == nil || interval != permissionInterval else { return }
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retryListening()
                if self.model.permission != .granted { self.watchForGrant() }
            }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        permissionInterval = interval
    }

    private func stopWatchingForGrant() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionInterval = 0
    }

    /// Looks for the grant without blocking the main thread; one look at a time.
    private func retryListening() {
        // A deaf tap is already running; only a relaunch can tell more.
        guard !silentAfterRelaunch, !probingGrant else { return }
        probingGrant = true
        Task { @MainActor [weak self] in
            let allowed = await InputAccess.preflight()
            guard let self else { return }
            self.probingGrant = false
            guard !self.silentAfterRelaunch else { return }
            if allowed, self.listener.start() {
                self.permissionGranted()
            } else {
                let state: AppModel.Permission = allowed ? .stale : .missing
                if state != self.model.permission { self.model.permission = state; self.onStateChange?() }
            }
        }
    }

    /// Adds Switchtone to the Input Monitoring list (so the user only flips a
    /// switch) and opens that exact pane.
    func requestInputMonitoring() {
        if model.permission == .missing && !model.accessRequested { markAccessRequested(); Self.showAccessPrompt() }
        if let url = Self.inputMonitoringURL { NSWorkspace.shared.open(url) }
        model.waitingForGrant = true
        if model.permission != .granted { watchForGrant() }
    }

    /// The "Allow…" button of the welcome window and Settings, and the first need for the permission:
    /// asks through the system prompt while macOS still shows it. Once it has been used (and denied or
    /// dismissed) the same button opens the exact Settings pane instead.
    func requestAccessPrompt() {
        guard model.permission != .granted else { return }
        if model.permission == .missing && !model.accessRequested {
            markAccessRequested()
            Self.showAccessPrompt()
            model.waitingForGrant = true
            watchForGrant()
        } else {
            requestInputMonitoring()
        }
    }

    private func markAccessRequested() {
        settings.askedForAccess = true
        model.accessRequested = true
    }

    /// The system's own prompt, which also adds Switchtone to the Input Monitoring list. Asked off the main
    /// thread, since the call goes to the permission service.
    private nonisolated static func showAccessPrompt() {
        DispatchQueue.global(qos: .userInitiated).async { _ = CGRequestListenEventAccess() }
    }

    /// Once the tap runs, make sure keys really come through. If the user
    /// types (the system's own last-key clock moves) but the tap has seen
    /// nothing, macOS wants a fresh process: relaunch quietly, once. If the
    /// fresh process is deaf too, the grant belongs to another copy and
    /// the panel asks for the switch to be turned off and on.
    private func watchForSilentTap() {
        let startedAt = Date()
        let receivedAtStart = listener.counters.received
        silentTapTimer?.invalidate()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let verdict = SilentTap.verdict(
                    heard: self.listener.counters.received > receivedAtStart,
                    elapsed: Date().timeIntervalSince(startedAt),
                    sinceLastKey: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
                    secureInput: IsSecureEventInputEnabled(),
                    sinceRelaunch: self.settings.silentTapRelaunchAt.map { Date().timeIntervalSince($0) })
                switch verdict {
                case .wait:
                    // Keys are being typed but another app has secure keyboard entry on: macOS hides every
                    // key from every tap then. Say so once, so a quiet counter is not mistaken for a deaf tap.
                    if !self.loggedSecureInput, IsSecureEventInputEnabled(),
                       CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < Date().timeIntervalSince(startedAt) {
                        self.loggedSecureInput = true
                        self.log.notice("secure keyboard entry is on in another app; macOS hides keys from every tap until it ends")
                    }
                    return
                case .healthy, .gaveUp:
                    if verdict == .healthy, self.silentAfterRelaunch {
                        self.silentAfterRelaunch = false
                        self.model.permission = .granted
                        self.onStateChange?()
                    }
                case .relaunch:
                    self.log.notice("keys typed but none reached Switchtone; relaunching once")
                    self.settings.silentTapRelaunchAt = Date()
                    self.relaunch()
                case .stale:
                    if !self.silentAfterRelaunch {
                        self.log.notice("keys typed but none reached Switchtone after a relaunch; the grant is stale")
                        self.model.permission = .stale
                        self.silentAfterRelaunch = true
                        self.onStateChange?()
                    }
                    return   // keep watching: the first key heard clears it
                }
                self.silentTapTimer?.invalidate()
                self.silentTapTimer = nil
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        silentTapTimer = timer
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        // The new process waits for this one to finish quitting (see SingleInstance).
        configuration.arguments = [SingleInstance.relaunchArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    Logger(subsystem: "info.gabrimatic.switchtone", category: "app").error("relaunch failed: \(message, privacy: .public)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Revoking Input Monitoring disables a running tap; go back to waiting.
    /// A tap macOS has switched off is caught at once; for a tap that still
    /// looks healthy the grant is confirmed off the main thread.
    func checkTapHealth() {
        guard model.permission == .granted, listener.isRunning else { return }
        if !listener.isHealthy { return revokedGrant() }
        Task { @MainActor [weak self] in
            guard !(await InputAccess.preflight()), let self else { return }
            // Still the same tap, and the grant is gone.
            if self.model.permission == .granted, self.listener.isRunning { self.revokedGrant() }
        }
    }

    private func revokedGrant() {
        log.notice("input monitoring revoked; waiting for it again")
        listener.stop()
        startListening()
    }

    // MARK: Actions

    func toggleEnabled() { setEnabled(!settings.enabled) }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        model.enabled = on
        // Switching the sounds on without the permission is the first need for it: ask now.
        if on, model.permission == .missing, !model.accessRequested { requestAccessPrompt() }
        if on { if model.audible { sound.warmUp() } } else { sound.stop() }
        log.notice("sounds \(on ? "on" : "off", privacy: .public)")
        publishSharedState()
        onStateChange?()
    }

    func choose(_ profile: Profile) {
        guard profile != model.profile else { return }
        settings.profile = profile
        model.profile = profile
        Haptics.perform(.generic)
        loadProfile(profile)
    }

    /// `final` is true when the slider is released: then play the new level once.
    func setVolume(_ value: Float, final: Bool) {
        let old = settings.volume
        settings.volume = value
        model.volume = settings.volume
        // A detent at the ends of the scale, as the system volume slider has.
        if (old > 0 && value <= 0) || (old < 1 && value >= 1) { Haptics.perform(.levelChange) }
        // At silence nothing plays, so the output is released at once; the first
        // step above it brings the output back before the next key.
        let wasMuted = old <= AppModel.silentVolume, isMuted = model.volumeMuted
        if isMuted != wasMuted {
            if isMuted { sound.stop() } else if model.audible { sound.warmUp() }
            onStateChange?()
        }
        if final, !model.volumeMuted {
            sound.preview([Strike(keyClass: .key, down: true, keyCode: 5, intensity: 0.6)], volume: model.volume)
        }
    }

    func setSpatial(_ on: Bool) {
        settings.spatial = on
        model.spatial = on
        sound.configure(spatial: on, headTracking: settings.headTracking)
        if !model.volumeMuted { sound.preview(Self.phrase(spread: true), volume: model.volume) }
    }

    func setHeadTracking(_ on: Bool) {
        settings.headTracking = on
        model.headTracking = on
        sound.configure(spatial: settings.spatial, headTracking: on)
    }

    /// Settings > Sounds > Trackpad tick.
    func setTrackpadTick(_ on: Bool) {
        settings.trackpadTick = on
        model.trackpadTick = on
        if on { tick.fire() }
    }

    func setMuteSecure(_ on: Bool) {
        settings.muteSecure = on
        model.muteSecure = on
    }

    func setFocusMuted(_ muted: Bool) {
        settings.focusMuted = muted
        model.focusMuted = muted
        if muted { sound.stop() }
        log.notice("focus filter: \(muted ? "muted" : "not muted", privacy: .public)")
        onStateChange?()
    }

    /// Settings > General > Show menu bar icon. Everything stays reachable from Settings either way.
    func setShowMenuBarIcon(_ on: Bool) {
        settings.showMenuBarIcon = on
        model.showMenuBarIcon = on
        log.notice("menu bar icon \(on ? "shown" : "hidden", privacy: .public)")
        onMenuBarIconChange?()
    }

    func setLogin(_ on: Bool) {
        if LoginItem.needsApproval {
            LoginItem.openSettings()
            return
        }
        if let error = LoginItem.set(on) {
            model.login = .failed
            log.error("login item change failed: \(error, privacy: .public)")
        } else {
            refreshLogin()
        }
    }

    func openLoginItems() { LoginItem.openSettings() }

    /// `offMain` reads the status (a call to the system's background-item service) on a
    /// background task, for the moment the panel opens.
    func refreshLogin(offMain: Bool = false) {
        func login(_ status: SMAppService.Status) -> AppModel.Login {
            status == .enabled ? .on : (status == .requiresApproval ? .needsApproval : .off)
        }
        guard offMain else { model.login = login(LoginItem.status); return }
        guard let probe = loginProbe else { return }
        Task { @MainActor [weak self] in
            let status = await Task.detached(priority: .userInitiated) { probe() }.value
            self?.model.login = login(status)
        }
    }

    func quit() { NSApp.terminate(nil) }

    func openSettings() { onShowSettings?() }

    // MARK: Windows

    /// The welcome window's Done button.
    func completeOnboarding() {
        settings.setOnboardingCompleted(true)
        model.onboardingPending = false
    }

    /// Settings > Permissions > Show Again: the welcome window shows again.
    func resetOnboarding() {
        settings.setOnboardingCompleted(false)
        model.onboardingPending = true
        onShowOnboarding?()
    }

    /// A Switchtone window (welcome, Settings) opened or the last one closed. While one is open the grant is
    /// read once a second and the login item's state is refreshed, so the rows are always current.
    func windowsChanged(anyOpen: Bool) {
        windowTimer?.invalidate()
        windowTimer = nil
        guard anyOpen else {
            if model.permission != .granted { watchForGrant() }
            return
        }
        refreshLogin(offMain: true)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.permission == .granted { self.checkTapHealth() } else { self.retryListening() }
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        windowTimer = timer
        if model.permission != .granted { retryListening() }
        permissionTimer?.invalidate()
        permissionTimer = nil
        permissionInterval = 0
    }

    /// Tells the Control Center control whether the sounds are on.
    private func publishSharedState() {
        guard SharedState.writeEnabled(settings.enabled) else {
            log.error("could not write the shared state for the control")
            return
        }
        ControlCenter.shared.reloadControls(ofKind: SharedState.controlKind)
    }

    /// On quit: the control shows off and unavailable-looking state until the next launch re-publishes.
    func publishNotRunning() {
        _ = SharedState.writeEnabled(false)
        ControlCenter.shared.reloadControls(ofKind: SharedState.controlKind)
    }

    /// Whether the latest profile choice has been swapped in.
    var loadedProfile: Profile? { sound.bankProfile }

    // MARK: Panel

    func panelWillOpen() {
        log.notice("panel opened: \(self.diagnostics, privacy: .public)")
        checkTapHealth()
        if model.permission != .granted { retryListening() }
        refreshLogin(offMain: true)
        if model.audible { sound.warmUp() }
        // Decode the other two profiles' preview banks now, in the background,
        // so the first hover over a card plays at once and costs the main thread nothing.
        for profile in Profile.allCases where profile != model.profile { _ = previewLoad(profile) }
    }

    /// The preview bank for a profile, decoded once off the main thread. Nil when its sounds cannot be read.
    private func previewLoad(_ profile: Profile) -> Task<SoundBank?, Never> {
        if let existing = previewLoads[profile] { return existing }
        let resources = self.resources
        let task = Task.detached(priority: .utility) {
            autoreleasepool { try? SoundBank.load(profile, from: resources) }
        }
        previewLoads[profile] = task
        return task
    }

    func panelDidClose() {
        stopPreview()
        if !previewLoads.isEmpty {
            previewLoads.removeAll()
            Self.returnFreedMemory()
        }
        model.waitingForGrant = model.waitingForGrant && model.permission != .granted
    }

    /// Hovering a card plays a short phrase in that profile after a short
    /// dwell, so sweeping the pointer across the cards stays quiet.
    func startPreview(_ profile: Profile) {
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, !Task.isCancelled, !self.model.volumeMuted else { return }
            var bank: SoundBank?
            if profile != self.sound.bankProfile {
                // Usually ready already (started when the panel opened); never decoded on this thread.
                bank = await self.previewLoad(profile).value
                guard bank != nil, !Task.isCancelled, !self.model.volumeMuted else { return }
            }
            self.model.previewing = profile
            self.sound.preview(Self.phrase(spread: false), volume: self.model.volume, bank: bank)
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled, self.model.previewing == profile { self.model.previewing = nil }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        if model.previewing != nil {
            model.previewing = nil
            sound.silence()
        }
    }

    /// "hello" and a space, typed at an easy pace. `spread` walks it from the
    /// left of the keyboard to the right so the 3D width is heard.
    nonisolated static func phrase(spread: Bool) -> [Strike] {
        let keys: [Int64] = spread ? [50, 13, 3, 38, 31, 51] : [4, 14, 37, 37, 31, 49]
        let downs: [Double] = [0, 0.12, 0.22, 0.35, 0.45, 0.62]
        var strikes: [Strike] = []
        for (i, key) in keys.enumerated() {
            let cls = KeyClass(keyCode: key)
            strikes.append(Strike(keyClass: cls, down: true, keyCode: key, intensity: 0.6, delay: downs[i]))
            strikes.append(Strike(keyClass: cls, down: false, keyCode: key, intensity: 0.6, delay: downs[i] + 0.075))
        }
        return strikes
    }

    /// Decoding a bank goes through large temporary arrays; give their pages
    /// back to the system instead of keeping them as empty malloc regions.
    nonisolated static func returnFreedMemory() {
        malloc_zone_pressure_relief(nil, 0)
    }

    // MARK: Diagnostics

    /// Writes the counters to the log now (the app does this on a `SIGUSR1`, so they can be read live).
    func logDiagnostics() {
        log.notice("counters: \(self.diagnostics, privacy: .public)")
    }

    var diagnostics: String {
        let keys = listener.counters, audio = sound.counters
        return "tick \(tick.count), received \(keys.received), played \(keys.played), repeat \(keys.skippedRepeat), secure \(keys.skippedSecure), "
            + "off \(keys.skippedDisabled), orphan releases \(keys.skippedOrphanRelease), tap delay median \(keys.tapDelayMedian) µs "
            + "p95 \(keys.tapDelayP95) µs avg \(keys.tapDelayAverage) µs max \(keys.tapDelayMax) µs, first key after quiet avg "
            + "\(keys.tapDelayAfterQuiet) µs (\(keys.afterQuietCount)); scheduled \(audio.scheduled), woke+played \(audio.playedWhileWaking), "
            + "woke+dropped \(audio.droppedWhileWaking), woke+lost \(audio.lostWhileWaking), refused \(audio.refused)"
    }
}
