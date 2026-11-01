import AVFAudio
import AudioToolbox
import CoreGraphics
import Foundation
import Synchronization
import os

/// One sound to play.
struct Strike: Sendable {
    var keyClass: KeyClass
    var down: Bool
    var keyCode: Int64
    /// 0 (slow, soft) to 1 (fast, hard). See `TypingDynamics`.
    var intensity: Float = 0.5
    /// Seconds from now; releases wait for the spring (`ReleaseTiming`).
    var delay: Double = 0
}

/// What the sound output is doing, for the UI.
struct EngineStatus: Equatable, Sendable {
    var route: AudioRoute = .none
    var algorithm: String = ""
    var spatial = true
    var headTracking = false
    var economy = false
    var problem: String?
}

/// Plays keyboard samples in place with as little latency and idle cost as possible.
///
/// Two paths share the voices in `StrikeMixer`, each ending in a 64-frame output buffer:
/// - The stereo stage (speakers, and 3D sound off): one stereo source node mixes every voice with its own
///   gain and inter-channel delay -> main mixer -> output. Nothing else touches the sound, so a key's
///   position is exactly what `StereoStage` says.
/// - HRTF (headphones): one mono source node per voice -> AVAudioEnvironmentNode (3D position per key,
///   distance attenuation) -> main mixer -> output.
///
/// - `play` runs on the event-tap thread and takes no lock. The key voices' bookkeeping and random
///   generator belong to that thread alone; the loaded bank, the clock of the last sound and a press
///   that arrives while the output sleeps cross threads as atomics. No allocation, no system RNG; a
///   strike goes to the render thread through a ring. On the HRTF path it also sets the voice's position.
/// - Previews (profile cards, the volume slider) and the presses that woke
///   the output play on their own voices from the `control` queue, so they
///   never share state with the tap thread.
/// - The engine pauses after a minute without a key so an idle Switchtone lets the
///   audio hardware and the Mac sleep. Wake, unlock, a modifier or a key starts
///   it again, and so does a click within two minutes of the last key (never a
///   scroll, never in Low Power Mode), so the usual click into a field restarts
///   it ahead of the next key. A key that still beats the restart is queued with
///   its release and plays within `wakeGrace` with its spacing kept.
final class SoundEngine: @unchecked Sendable {
    static let voiceCount = 8
    static let previewVoiceCount = 6
    /// A replaced bank is released this long after the swap, so a keystroke
    /// that read it just before can finish scheduling from it.
    static let bankReleaseDelay: TimeInterval = 2
    /// The running output costs about 1 to 2% of a core (the 64-frame IO cycle,
    /// whatever the voices do) and holds the audio hardware on, so it pauses
    /// after this long without a key. Coming back (wake, unlock, a modifier,
    /// a key, or a click inside a typing session) starts it again.
    static let idleSuspendSeconds: TimeInterval = 60
    static let idleCheckInterval: TimeInterval = 10
    /// A press that arrives while the output is asleep still plays if the
    /// output is ready within this time. A restart measures 35 to 70 ms on the
    /// built-in speakers, so this leaves room for the slow end; a press later
    /// than that is dropped rather than played as a stray late click.
    static let wakeGrace = 0.12
    /// Every recording plays a little slower than it was made: a heavier cap on a solid case.
    static let weight: Float = 0.93
    /// Releases are softer than presses.
    static let releaseLevel: Float = 0.72
    /// Headroom so fast, loud typing never clips.
    static let baseLevel: Float = 0.8

    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    private let mixer = StrikeMixer(keyVoices: SoundEngine.voiceCount, previewVoices: SoundEngine.previewVoiceCount, rate: SoundBank.rate)
    /// The stereo stage's one node.
    private var stageNode: AVAudioSourceNode?
    /// The HRTF path's nodes, one per voice.
    private let voiceNodes: [AVAudioSourceNode]
    private let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "audio")

    /// Which voice to use next and which sample: the voice that finished (or
    /// will finish) first, and a deterministic random pick.
    private struct VoicePool {
        var ends: [UInt64]
        var rng: SplitMix64
    }
    /// Only the thread that calls `play` (the event tap) touches this.
    private var keyPool = VoicePool(ends: [UInt64](repeating: 0, count: SoundEngine.voiceCount), rng: SplitMix64(seed: 0x436C_6163_6B21))
    /// Only `control` touches this.
    private var previewPool = VoicePool(ends: [UInt64](repeating: 0, count: SoundEngine.previewVoiceCount), rng: SplitMix64(seed: 0x7072_6576))
    /// Bumped by `silence` so preview strikes still waiting to play are dropped. `control` only.
    private var previewGeneration = 0

    /// The loaded bank as a retained object pointer (0: none). Swapped
    /// atomically; the old one is released later (`bankReleaseDelay`).
    private let bankBits = Atomic<UInt>(0)
    private let lastPlay = Atomic<UInt64>(0)
    /// Host time of the latest real key (not a preview, not a restart); 0 until one is typed.
    private let lastKey = Atomic<UInt64>(0)
    /// Low Power Mode or thermal pressure, mirrored from `economy` for the tap thread.
    private let economyFlag = Atomic<Bool>(false)
    /// Presses and releases that arrived while the output slept, in order.
    private let wakeRing = WakeRing()
    /// Which path a strike takes: 0 the stereo stage, 1 plain stereo, 2 HRTF. Set on `control`, read on the tap thread.
    private let pathBits = Atomic<UInt8>(0)
    private let running = Atomic<Bool>(false)
    private let starting = Atomic<Bool>(false)
    private let scheduledCount = Atomic<Int>(0)
    private let wokenCount = Atomic<Int>(0)
    private let droppedWaking = Atomic<Int>(0)
    private let lostWaking = Atomic<Int>(0)
    private let refused = Atomic<Int>(0)

    /// Serializes engine start, pause, reconfiguration and the idle timer.
    let control = DispatchQueue(label: "info.gabrimatic.switchtone.audio", qos: .userInitiated)
    // Touched only on `control`.
    private var route = AudioRoute.none
    private var spatial = true
    private var headTracking = true
    private var economy = false { didSet { economyFlag.store(economy, ordering: .relaxed) } }
    private var applied: RenderPolicy.Choice?
    /// The HRTF renderer loads its data when first selected, so nothing is
    /// selected until the output first starts.
    private var hasStarted = false
    private var environmentConnected = false
    private var idleTimer: DispatchSourceTimer?
    private var problem: String?
    private var routeMonitor: AudioRouteMonitor?
    private var observers: [NSObjectProtocol] = []
    private var pendingPreviews: [(strikes: [Strike], volume: Float, bank: SoundBank?)] = []

    /// Called on the main queue whenever the status changes.
    var onStatus: (@Sendable (EngineStatus) -> Void)?
    /// Called (on `control`) when the output pauses, with the reason.
    var onPaused: (@Sendable (String) -> Void)?

    init() {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: SoundBank.rate, channels: 2)
        let mono = AVAudioFormat(standardFormatWithSampleRate: SoundBank.rate, channels: 1)
        let mixer = self.mixer
        voiceNodes = (0..<(Self.voiceCount + Self.previewVoiceCount)).map { slot in
            guard let mono else { fatalError("the mono format always exists") }
            return AVAudioSourceNode(format: mono) { isSilence, _, frameCount, data in
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                let count = Int(frameCount)
                guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if !mixer.renderVoice(slot, count: count, out: out) {
                    out.update(repeating: 0, count: count)
                    isSilence.pointee = true
                }
                return noErr
            }
        }
        if let stereo {
            stageNode = AVAudioSourceNode(format: stereo) { isSilence, _, frameCount, data in
                let buffers = UnsafeMutableAudioBufferListPointer(data)
                let count = Int(frameCount)
                guard buffers.count > 1, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if !mixer.renderStereo(count: count, left: left, right: right) {
                    left.update(repeating: 0, count: count)
                    right.update(repeating: 0, count: count)
                    isSilence.pointee = true
                }
                return noErr
            }
        }
        engine.attach(environment)
        for voice in voiceNodes {
            engine.attach(voice)
            engine.connect(voice, to: environment, format: mono)
            voice.sourceMode = .pointSource
            voice.pointSourceInHeadMode = .mono
            voice.position = SpatialScene.center
        }
        if let stageNode {
            engine.attach(stageNode)
            engine.connect(stageNode, to: engine.mainMixerNode, format: stereo)
        }

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = SpatialScene.referenceDistance
        attenuation.maximumDistance = 4
        attenuation.rolloffFactor = 1
        engine.prepare()

        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.configurationChanged() }
        })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.control.async { self.updateEconomy() }
            })
        }
        control.async { [self] in
            updateEconomy(apply: false)
            let monitor = AudioRouteMonitor(queue: control) { [weak self] route in self?.routeChanged(route) }
            routeMonitor = monitor
            monitor.start()
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let bits = bankBits.exchange(0, ordering: .acquiringAndReleasing)
        if let pointer = UnsafeRawPointer(bitPattern: bits) { Unmanaged<SoundBank>.fromOpaque(pointer).release() }
    }

    // MARK: Bank

    func setBank(_ bank: SoundBank) {
        let bits = UInt(bitPattern: Unmanaged.passRetained(bank).toOpaque())
        let old = bankBits.exchange(bits, ordering: .acquiringAndReleasing)
        if old != 0 {
            control.asyncAfter(deadline: .now() + Self.bankReleaseDelay) {
                if let pointer = UnsafeRawPointer(bitPattern: old) { Unmanaged<SoundBank>.fromOpaque(pointer).release() }
                // The old bank's pages go back to the system now, not at the next memory squeeze.
                malloc_zone_pressure_relief(nil, 0)
            }
        }
        log.info("loaded profile \(bank.profile.rawValue, privacy: .public): \(bank.frameCount) frames")
    }

    /// The loaded bank. Lock-free; the returned reference keeps it alive.
    private var bank: SoundBank? {
        guard let pointer = UnsafeRawPointer(bitPattern: bankBits.load(ordering: .acquiring)) else { return nil }
        return Unmanaged<SoundBank>.fromOpaque(pointer).takeUnretainedValue()
    }

    var bankProfile: Profile? { bank?.profile }

    // MARK: Playback

    /// Plays one strike. Call it from one thread only (the event tap): the
    /// key voices belong to that thread. It never waits for a lock or the
    /// audio hardware: if the output is asleep, this wakes it and the press
    /// plays only if the output is ready within `wakeGrace`.
    func play(_ strike: Strike, volume: Float) {
        lastKey.store(HostClock.now, ordering: .relaxed)
        guard running.load(ordering: .acquiring) else {
            if !wakeRing.push(strike, volume: volume, at: HostClock.now) {
                lostWaking.add(1, ordering: .relaxed)
            }
            startInBackground()
            return
        }
        schedule(strike, volume: volume, bank: bank, ring: mixer.keyRing, firstSlot: 0, pool: &keyPool)
    }

    /// Hands the strike to the voice in the pool that finishes first, as a command for the next audio cycle.
    private func schedule(_ strike: Strike, volume: Float, bank: SoundBank?, ring: StrikeRing, firstSlot: Int, pool: inout VoicePool) {
        guard let bank, let variants = bank.variants(strike.keyClass, down: strike.down), !variants.isEmpty else { return }
        let now = HostClock.now
        let start = now &+ HostClock.ticks(seconds: strike.delay)
        let sample = variants[pool.rng.index(below: variants.count)]
        // Fast fingers land lighter, so the tone darkens with speed.
        let bright = pool.rng.unit() >= strike.intensity
        // Each key has its own slight tuning; a press nudges it a step either way.
        let steps = SoundBank.pitchSteps
        let home = Int(UInt64(bitPattern: strike.keyCode &* 2_654_435_761) % UInt64(steps.count - 2)) + 1
        let step = steps[min(steps.count - 1, max(0, home + pool.rng.index(below: 3) - 1))] * Self.weight
        let length = StrikeMixer.voiceFrames(speed: strike.intensity, spread: pool.rng.float(in: 0.85...1.15))
        var voice = 0
        for i in 1..<pool.ends.count where pool.ends[i] < pool.ends[voice] { voice = i }
        pool.ends[voice] = start &+ HostClock.ticks(seconds: min(Double(length) / SoundBank.rate, Double(sample.frames) / SoundBank.rate / Double(step)))
        let jitter = strike.down ? pool.rng.float(in: 0.86...1.0) : pool.rng.float(in: 0.8...1.0)
        lastPlay.store(now, ordering: .relaxed)

        let slot = firstSlot + voice
        // A key let go at speed barely tops out, so its release fades with the speed but never stops.
        let release = Self.releaseLevel * (1 - 0.75 * strike.intensity)
        let level = Self.baseLevel * TypingDynamics.gain(strike.intensity) * jitter * (strike.down ? 1 : release)
        let gain = min(1, max(0, volume * level))
        var command = StrikeCommand(slot: Int32(slot), sample: sample, step: step, gainLeft: gain, gainRight: gain, delayLeft: 0, delayRight: 0,
                                    softness: bright ? 0 : SoundBank.softAmount, startHost: 0, length: Int32(length), bodyHz: StrikeBody.note(keyCode: strike.keyCode, big: strike.keyClass.isStabilized),
                                    bodyDrive: StrikeBody.drive(speed: strike.intensity, press: strike.down))
        command.startHost = strike.delay > 0 ? start : 0
        let path = pathBits.load(ordering: .relaxed)
        if path == 2 {
            voiceNodes[slot].position = SpatialScene.position(forKeyCode: strike.keyCode)
        } else {
            let placement = StereoStage.lookup(strike.keyCode, kind: path == 0 ? .speakers : .plain)
            command.gainLeft = gain * placement.gainLeft
            command.gainRight = gain * placement.gainRight
            command.delayLeft = placement.delayLeft
            command.delayRight = placement.delayRight
        }
        if ring.push(command) {
            scheduledCount.add(1, ordering: .relaxed)
        } else {
            refused.add(1, ordering: .relaxed)
        }
    }

    /// Plays a short phrase, for the profile cards and the volume slider, on
    /// the preview voices. A late start is fine here because no key was pressed.
    func preview(_ strikes: [Strike], volume: Float, bank: SoundBank? = nil) {
        // Decided on `control`, serialized with startEngine: a start that is
        // already under way either has finished (play now) or will drain this.
        control.async { [self] in
            if running.load(ordering: .acquiring) {
                startPreview(strikes, volume: volume, bank: bank)
            } else {
                pendingPreviews.append((strikes, volume, bank))
                if !starting.load(ordering: .acquiring) { startInBackground() }
            }
        }
    }

    /// Runs on `control`. Each strike is handed to a voice when it is due, so
    /// a whole phrase fits on the preview voices and `silence` can still drop the rest.
    private func startPreview(_ strikes: [Strike], volume: Float, bank: SoundBank?) {
        let generation = previewGeneration
        for strike in strikes {
            guard strike.delay > 0 else { playPreview(strike, volume: volume, bank: bank); continue }
            let due = Strike(keyClass: strike.keyClass, down: strike.down, keyCode: strike.keyCode, intensity: strike.intensity)
            control.asyncAfter(deadline: .now() + strike.delay) { [weak self] in
                guard let self, self.previewGeneration == generation, self.running.load(ordering: .acquiring) else { return }
                self.playPreview(due, volume: volume, bank: bank)
            }
        }
    }

    /// Runs on `control`.
    private func playPreview(_ strike: Strike, volume: Float, bank override: SoundBank?) {
        schedule(strike, volume: volume, bank: override ?? bank, ring: mixer.previewRing, firstSlot: Self.voiceCount, pool: &previewPool)
        // A voice reads the bank's memory directly, so a preview bank stays alive until the strike has played.
        if let override { control.asyncAfter(deadline: .now() + Self.bankReleaseDelay) { withExtendedLifetime(override) {} } }
    }

    /// Stops the preview now (hover ended). Typing is never cut off.
    func silence() {
        control.async { [self] in
            previewGeneration &+= 1
            pendingPreviews.removeAll()
            guard running.load(ordering: .acquiring) else { return }
            mixer.cutPreviewVoices()
            previewPool.ends = [UInt64](repeating: 0, count: Self.previewVoiceCount)
        }
    }

    // MARK: Engine lifecycle

    /// Starts the output ahead of the first keystroke (launch, switching on, opening the panel).
    func warmUp() {
        if !running.load(ordering: .acquiring) { startInBackground() }
    }

    /// A click: starts the output ahead of the next key, but only inside a typing session
    /// (a key in the last `IdlePolicy.clickWarmSeconds`) and never in Low Power Mode or under
    /// thermal pressure. Clicking around while reading lets the output stay asleep.
    /// Lock-free (the event-tap thread calls it); one atomic load when the output runs.
    func warmForClick() {
        guard !running.load(ordering: .acquiring) else { return }
        let last = lastKey.load(ordering: .relaxed)
        let since = last == 0 ? nil : HostClock.seconds(ticks: HostClock.now &- last)
        guard IdlePolicy.warmsForClick(sinceLastKey: since, economy: economyFlag.load(ordering: .relaxed)) else { return }
        startInBackground()
    }

    private func startInBackground() {
        guard starting.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        control.async { [self] in startEngine() }
    }

    /// Runs on `control`. Starting the output takes tens of milliseconds, so
    /// it happens here and the tap thread never waits for it.
    private func startEngine() {
        defer { starting.store(false, ordering: .releasing) }
        guard !running.load(ordering: .acquiring) else { return }
        let began = HostClock.now
        do {
            applyRendering(force: true)
            setLowLatencyBuffer()
            // Strikes that raced an output change, and voices cut off by it, are dropped, so a
            // restart never fires a burst of stale clicks.
            mixer.reset()
            try engine.start()
            running.store(true, ordering: .releasing)
            let ready = HostClock.now
            lastPlay.store(ready, ordering: .relaxed)
            replayWaking(ready: ready)
            let previews = pendingPreviews
            pendingPreviews.removeAll()
            for p in previews { startPreview(p.strikes, volume: p.volume, bank: p.bank) }
            scheduleIdleCheck()
            setProblem(nil)
            let path = OutputPath.current()
            log.info("audio engine started in \(Int(HostClock.seconds(ticks: ready &- began) * 1000)) ms, output path \(path?.description ?? "unknown", privacy: .public)")
        } catch {
            pendingPreviews.removeAll()
            lostWaking.add(wakeRing.discard(), ordering: .relaxed)
            setProblem("No sound output is available. Switchtone tries again on the next key.")
            log.error("audio engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs on `control`, once the output is ready. Every press and release
    /// that arrived while it slept and is still inside `wakeGrace` plays, in
    /// order and with its spacing kept: the first one now, the rest after the
    /// gap they had. Older ones are counted as dropped. The key voices belong
    /// to the tap thread, so these play on the preview voices.
    private func replayWaking(ready: UInt64) {
        var base: UInt64 = 0
        let drained = wakeRing.drain { entry in
            if ready >= entry.at, HostClock.seconds(ticks: ready &- entry.at) <= Self.wakeGrace {
                if base == 0 { base = entry.at }
                var strike = entry.strike
                strike.delay += HostClock.seconds(ticks: entry.at &- base)
                playPreview(strike, volume: entry.volume, bank: nil)
                wokenCount.add(1, ordering: .relaxed)
            } else {
                droppedWaking.add(1, ordering: .relaxed)
            }
        }
        _ = drained
    }

    /// The default output buffer is 512 frames (~10.7 ms at 48 kHz), so a press
    /// lands anywhere from 0 to 10 ms late, which you hear as uneven timing when
    /// typing fast. 64 frames (~1.3 ms) keeps every press tight; the device
    /// clamps the value to its own supported range.
    private func setLowLatencyBuffer() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 64
        let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                          &frames, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr { log.error("could not lower the output buffer: \(status)") }
    }

    /// Pauses the engine after a quiet stretch. A running output keeps the
    /// audio hardware on and holds a "prevent idle sleep" assertion.
    private func scheduleIdleCheck() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + Self.idleCheckInterval, repeating: Self.idleCheckInterval, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.suspendIfIdle() }
        idleTimer = timer
        timer.resume()
    }

    /// Runs on `control`.
    private func suspendIfIdle() {
        let last = lastPlay.load(ordering: .relaxed)
        guard running.load(ordering: .acquiring) else { return }
        let sinceKey = HostClock.seconds(ticks: HostClock.now &- last)
        guard IdlePolicy.shouldPause(sinceLastKey: sinceKey) else { return }
        pause(reason: "idle")
    }

    /// Runs on `control`.
    private func pause(reason: StaticString) {
        running.store(false, ordering: .releasing)
        previewGeneration &+= 1
        engine.pause()
        idleTimer?.cancel()
        idleTimer = nil
        previewPool.ends = [UInt64](repeating: 0, count: Self.previewVoiceCount)
        log.info("audio engine paused (\(reason, privacy: .public))")
        onPaused?(reason.description)
    }

    /// After the Mac wakes: the output can stop across sleep without a
    /// configuration-change notice, which would leave every key queued on a
    /// stopped player. Restart it if it claims to run but is not.
    func recoverAfterWake() {
        control.async { [self] in
            guard running.load(ordering: .acquiring), !engine.isRunning else { return }
            log.notice("audio engine stopped across sleep; restarting")
            running.store(false, ordering: .releasing)
            startEngine()
        }
    }

    /// Stops all sound (Switchtone switched off or quitting).
    func stop() {
        control.async { [self] in
            guard running.load(ordering: .acquiring) else { return }
            pause(reason: "off")
        }
    }

    /// Runs on `control`. The output device changed (headphones, AirPlay,
    /// sleep): the engine has stopped itself; reconfigure and start again.
    private func configurationChanged() {
        let wasRunning = running.load(ordering: .acquiring)
        running.store(false, ordering: .releasing)
        log.info("audio configuration changed")
        route = AudioRoute.current()
        applied = nil
        if wasRunning { startEngine() } else { publish() }
    }

    // MARK: Rendering choice

    /// Applies the user's 3D and head-tracking choices.
    func configure(spatial: Bool, headTracking: Bool) {
        control.async { [self] in
            self.spatial = spatial
            self.headTracking = headTracking
            applyRendering(force: false)
        }
    }

    /// Set the route and rendering synchronously.
    func configureNow(route: AudioRoute, spatial: Bool, headTracking: Bool = false, economy: Bool = false) -> RenderPolicy.Choice? {
        control.sync {
            self.route = route
            self.spatial = spatial
            self.headTracking = headTracking
            self.economy = economy
            applyRendering(force: true)
            return applied
        }
    }

    private func routeChanged(_ route: AudioRoute) {
        self.route = route
        applyRendering(force: false)
    }

    private func updateEconomy(apply: Bool = true) {
        let info = ProcessInfo.processInfo
        let value = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        guard value != economy else { return }
        economy = value
        log.info("economy rendering \(value ? "on" : "off", privacy: .public)")
        if apply { applyRendering(force: false) }
    }

    /// Runs on `control`.
    private func applyRendering(force: Bool) {
        guard hasStarted || force else { publishPending(); return }
        hasStarted = true
        // The environment node is what offers the renderers, so it has to be in the graph to ask it.
        if route.kind == .headphones && spatial { connectEnvironment(true) }
        let applicable = environmentConnected
            ? environment.applicableRenderingAlgorithms.compactMap { AVAudio3DMixingRenderingAlgorithm(rawValue: $0.intValue) } : []
        let choice = RenderPolicy.choose(kind: route.kind, spatial: spatial, headTracking: headTracking, economy: economy,
                                         applicable: applicable)
        guard force || choice != applied else { publish(); return }
        let hrtf = choice.path == .spatial
        // Out of the graph unless it plays: running idle it costs 1.6% of a core.
        connectEnvironment(hrtf)
        environment.outputType = choice.outputType
        environment.isListenerHeadTrackingEnabled = choice.headTracking
        for voice in voiceNodes {
            // The renderers load their data when selected, so the stereo stage never selects one.
            voice.renderingAlgorithm = hrtf ? choice.algorithm : .equalPowerPanning
        }
        mixer.setDirect(!hrtf)
        pathBits.store(hrtf ? 2 : (choice.path == .stage ? 0 : 1), ordering: .relaxed)
        applied = choice
        log.info("rendering: \(choice.label, privacy: .public) for \(self.route.kind.rawValue, privacy: .public), head tracking \(choice.headTracking)")
        publish()
    }

    /// Runs on `control`.
    private func connectEnvironment(_ on: Bool) {
        guard on != environmentConnected else { return }
        if on {
            engine.connect(environment, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: SoundBank.rate, channels: 2))
        } else {
            engine.disconnectNodeOutput(environment)
        }
        environmentConnected = on
    }

    /// Before the first start: report the route and choices without loading a renderer.
    private func publishPending() {
        guard let onStatus else { return }
        let headphones = route.kind == .headphones
        let status = EngineStatus(route: route, algorithm: "", spatial: spatial, headTracking: spatial && headphones && headTracking,
                                  economy: economy, problem: problem)
        DispatchQueue.main.async { onStatus(status) }
    }

    private func setProblem(_ message: String?) {
        guard message != problem else { return }
        problem = message
        publish()
    }

    /// Runs on `control`.
    private func publish() {
        guard let onStatus else { return }
        let status = EngineStatus(route: route, algorithm: applied?.label ?? "", spatial: spatial,
                                  headTracking: applied?.headTracking ?? false, economy: economy, problem: problem)
        DispatchQueue.main.async { onStatus(status) }
    }

    // MARK: Diagnostics

    struct Counters: Sendable {
        var scheduled: Int
        var playedWhileWaking: Int
        var droppedWhileWaking: Int
        /// Presses that found the wake queue full (a long outage of the output).
        var lostWhileWaking: Int
        /// Strikes that found the voices' queue full (the output stalled while keys kept coming).
        var refused: Int
    }

    var counters: Counters {
        Counters(scheduled: scheduledCount.load(ordering: .relaxed), playedWhileWaking: wokenCount.load(ordering: .relaxed),
                 droppedWhileWaking: droppedWaking.load(ordering: .relaxed),
                 lostWhileWaking: lostWaking.load(ordering: .relaxed), refused: refused.load(ordering: .relaxed))
    }

    var isRunning: Bool { running.load(ordering: .acquiring) }
}

/// When a running output may pause: a minute without a key. A pause costs the
/// next key a restart of tens of milliseconds (it still plays, see `wakeGrace`),
/// and the output is started ahead of that key whenever the person returns.
enum IdlePolicy {
    static func shouldPause(sinceLastKey: TimeInterval) -> Bool {
        sinceLastKey >= SoundEngine.idleSuspendSeconds
    }

    /// A click restarts a paused output only this soon after the last key: the person is in
    /// a typing session and likely about to type again.
    static let clickWarmSeconds: TimeInterval = 120

    /// Whether a click should start a sleeping output. `sinceLastKey` is nil when no key was typed yet.
    static func warmsForClick(sinceLastKey: TimeInterval?, economy: Bool) -> Bool {
        guard !economy, let sinceLastKey else { return false }
        return sinceLastKey < clickWarmSeconds
    }
}


/// A small single-producer, single-consumer queue of the strikes that arrive
/// while the output sleeps. The tap thread pushes without a lock or allocation;
/// `control` drains it once the output runs. When it is full the newest strike
/// is refused and the caller counts it.
final class WakeRing: Sendable {
    static let capacity = 32

    struct Entry {
        var strike: Strike
        var volume: Float
        var at: UInt64
    }

    private final class Slot: Sendable {
        let at = Atomic<UInt64>(0)
        /// key code (16 bits) | down (bit 16) | delay as Float bits (high 32 bits)
        let meta = Atomic<UInt64>(0)
        /// intensity bits (low 32) | volume bits (high 32)
        let level = Atomic<UInt64>(0)
    }

    private let slots: [Slot] = (0..<WakeRing.capacity).map { _ in Slot() }
    /// Next index to write (producer) and next to read (consumer); both only grow.
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    /// Tap thread only. False when the queue is full.
    func push(_ strike: Strike, volume: Float, at: UInt64) -> Bool {
        let h = head.load(ordering: .relaxed)
        guard h &- tail.load(ordering: .acquiring) < Self.capacity else { return false }
        let slot = slots[h % Self.capacity]
        let code = UInt64(UInt16(truncatingIfNeeded: strike.keyCode))
        slot.meta.store(code | (strike.down ? 1 << 16 : 0) | (UInt64(Float(strike.delay).bitPattern) << 32), ordering: .relaxed)
        slot.level.store(UInt64(strike.intensity.bitPattern) | (UInt64(volume.bitPattern) << 32), ordering: .relaxed)
        slot.at.store(at, ordering: .relaxed)
        head.store(h &+ 1, ordering: .releasing)
        return true
    }

    /// One consumer at a time (`control`). Calls `body` for every queued entry, oldest first.
    @discardableResult
    func drain(_ body: (Entry) -> Void) -> Int {
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let count = h &- t
        while t != h {
            let slot = slots[t % Self.capacity]
            let meta = slot.meta.load(ordering: .relaxed), level = slot.level.load(ordering: .relaxed)
            let code = Int64(meta & 0xFFFF)
            let strike = Strike(keyClass: KeyClass(keyCode: code), down: meta & (1 << 16) != 0, keyCode: code,
                                intensity: Float(bitPattern: UInt32(truncatingIfNeeded: level)),
                                delay: Double(Float(bitPattern: UInt32(truncatingIfNeeded: meta >> 32))))
            body(Entry(strike: strike, volume: Float(bitPattern: UInt32(truncatingIfNeeded: level >> 32)), at: slot.at.load(ordering: .relaxed)))
            t &+= 1
        }
        tail.store(t, ordering: .releasing)
        return count
    }

    /// Empties the queue and returns how many strikes it held.
    func discard() -> Int { drain { _ in } }
}
