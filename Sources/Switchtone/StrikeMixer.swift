import AudioToolbox
import Darwin
import Synchronization

/// One strike on its way to the render thread: pointers into a loaded bank and how to play them.
/// Plain data, so handing it over allocates nothing and takes no lock.
struct StrikeCommand: Sendable {
    /// The voice to play on.
    var slot: Int32
    var sample: SoundBank.Sample
    /// Read speed: 1 is the recorded pitch.
    var step: Float
    var gainLeft: Float
    var gainRight: Float
    /// How many frames each channel starts after the other (the near side has 0).
    var delayLeft: Int32
    var delayRight: Int32
    /// 0 is the bright tone; `SoundBank.softAmount` is the soft one.
    var softness: Float
    /// When it should sound, on the host clock; 0 means as soon as the next cycle starts.
    var startHost: UInt64
    /// Frames until it has rung out.
    var length: Int32
    /// The case under this key: the note it rings at, and how hard the strike drives it.
    var bodyHz: Float
    var bodyDrive: Float
}

/// Hands strikes from one thread to the render thread. One writer, one reader, no lock, no allocation.
/// When it is full the newest strike is refused and the caller counts it.
final class StrikeRing: @unchecked Sendable {
    static let capacity = 64

    private let slots = UnsafeMutablePointer<StrikeCommand>.allocate(capacity: StrikeRing.capacity)
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    /// The reader skips everything before this position (set by `discardQueued`).
    private let skipTo = Atomic<Int>(0)

    deinit { slots.deallocate() }

    func push(_ command: StrikeCommand) -> Bool {
        let h = head.load(ordering: .relaxed)
        guard h &- tail.load(ordering: .acquiring) < Self.capacity else { return false }
        (slots + (h % Self.capacity)).initialize(to: command)
        head.store(h &+ 1, ordering: .releasing)
        return true
    }

    /// Render thread.
    @inline(__always)
    func pop() -> StrikeCommand? {
        var t = tail.load(ordering: .relaxed)
        let skip = skipTo.load(ordering: .acquiring)
        if skip &- t > 0 { t = skip; tail.store(t, ordering: .releasing) }
        guard head.load(ordering: .acquiring) != t else { return nil }
        let command = slots[t % Self.capacity]
        tail.store(t &+ 1, ordering: .releasing)
        return command
    }

    /// Drops what is queued now; a strike pushed after this call still plays. Any thread.
    func discardQueued() { skipTo.store(head.load(ordering: .acquiring), ordering: .releasing) }
}

/// The voices Switchtone plays from: every sample is read directly on the render thread, so a strike
/// waits only for the next audio cycle.
///
/// The event tap and the control queue each push into their own ring. Once per block the render thread
/// takes what is there and starts it. On the direct path one stereo block mixes every voice with its
/// own gains and inter-channel delay; on the HRTF path each voice has its own mono block in front of
/// the environment node, which places it. Pitch and tone are worked out while reading, so a bank is one
/// copy of each recording.
///
/// No lock and no allocation on the render thread. The pointers stay valid because a bank outlives
/// its last strike (`SoundEngine.bankReleaseDelay`), and `reset` forgets every voice before a restart.
final class StrikeMixer: @unchecked Sendable {
    private struct Voice {
        var active = false
        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var frames = 0
        var position: Double = 0
        var step: Double = 1
        var gainLeft: Float = 0
        var gainRight: Float = 0
        var delayLeft = 0
        var delayRight = 0
        var softness: Float = 0
        var lowLeft: Float = 0
        var lowRight: Float = 0
        /// Frames of silence left before it starts.
        var wait = 0
        /// Frames played so far, not counting the wait.
        var played = 0
        /// Frames left of a fade-out; -1 while it plays at full level.
        var fade = -1
        /// Frames until it has rung out.
        var length = 0
        /// Frames at full level before it starts to ring out.
        var hold = 0
        /// The level it has rung down to, and the step per frame once the hold is over.
        var ring: Float = 1
        var decay: Float = 1
        /// The case resonance: a two-pole filter the strike itself excites, so a real hit makes the
        /// body ring and a light one barely moves it.
        var bodyA: Float = 0
        var bodyB: Float = 0
        var bodyDrive: Float = 0
        var body1: Float = 0
        var body2: Float = 0
        /// The length of the current fade-out.
        var fadeLength = StrikeMixer.fadeFrames
    }

    /// Rolls off the tone of a soft strike (the same corner as `SoundBank.soften`).
    static let softCoefficient = Float(exp(-2 * Double.pi * SoundBank.softCorner / SoundBank.rate))
    /// A cut preview fades over 2 ms, so it never clicks.
    static let fadeFrames = 96
    /// A slow strike rings out over 80 ms, a strike at full typing speed over 40 ms. The hit is over in
    /// a fraction of that and the rest is a quiet tail. Nothing cuts a strike off: like keys on a real
    /// board, each one sounds on its own and they overlap freely.
    static let fullFrames = 3840
    static func voiceFrames(speed: Float, spread: Float = 1) -> Int {
        Int(Double(fullFrames) * (1 - 0.5 * Double(min(1, max(0, speed)))) * Double(spread))
    }
    /// How long the case takes to fall by 63%, in seconds.
    static let bodyDamping = 0.022
    /// How strongly a full strike drives the case, measured against the recordings.
    static let bodyLevel: Float = 0.03
    /// How far down a strike has rung at its end: -40 dB. The recording has faded further by then,
    /// so it never ends with a click, and the tail stays alive under the next key.
    static let ringFloor = 0.01

    let keyRing = StrikeRing()
    let previewRing = StrikeRing()
    let voiceCount: Int
    /// Voices from this slot on belong to previews.
    let firstPreviewSlot: Int
    private let voices: UnsafeMutablePointer<Voice>
    private let framesPerTick: Double
    private let forgetAll = Atomic<Bool>(false)
    private let cutPreviews = Atomic<Bool>(false)
    /// True: the stereo block plays. False: the per-voice blocks do.
    private let directPath = Atomic<Bool>(true)

    init(keyVoices: Int, previewVoices: Int, rate: Double) {
        voiceCount = keyVoices + previewVoices
        firstPreviewSlot = keyVoices
        voices = .allocate(capacity: voiceCount)
        voices.initialize(repeating: Voice(), count: voiceCount)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        framesPerTick = rate * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    deinit {
        voices.deinitialize(count: voiceCount)
        voices.deallocate()
    }

    func setDirect(_ direct: Bool) { directPath.store(direct, ordering: .relaxed) }

    /// Forgets every voice and everything queued. Called before the output starts again.
    func reset() {
        keyRing.discardQueued()
        previewRing.discardQueued()
        forgetAll.store(true, ordering: .releasing)
    }

    /// Stops the preview voices, with a short fade, and drops the previews still queued.
    func cutPreviewVoices() {
        previewRing.discardQueued()
        cutPreviews.store(true, ordering: .releasing)
    }

    // MARK: Render thread

    private func take() {
        if forgetAll.exchange(false, ordering: .acquiringAndReleasing) {
            for i in 0..<voiceCount { voices[i].active = false }
        }
        if cutPreviews.exchange(false, ordering: .acquiringAndReleasing) {
            for i in firstPreviewSlot..<voiceCount where voices[i].active && voices[i].fade < 0 { fadeOut(voices + i, over: Self.fadeFrames) }
        }
        var now: UInt64 = 0
        while let command = keyRing.pop() {
            if now == 0 { now = mach_absolute_time() }
            start(command, now: now)
        }
        while let command = previewRing.pop() {
            if now == 0 { now = mach_absolute_time() }
            start(command, now: now)
        }
    }

    @inline(__always)
    private func fadeOut(_ v: UnsafeMutablePointer<Voice>, over frames: Int) {
        v.pointee.fade = frames
        v.pointee.fadeLength = frames
    }

    /// What is ringing on these voices right now, as a sum of energy: 1 is one strike at full level.
    @inline(__always)
    private func ringing(_ slots: Range<Int>) -> Float {
        var energy: Float = 0
        for i in slots where voices[i].active && voices[i].wait == 0 {
            energy += voices[i].ring * voices[i].ring
        }
        return energy
    }

    private func start(_ command: StrikeCommand, now: UInt64) {
        guard command.slot >= 0, Int(command.slot) < voiceCount else { return }
        let wait = command.startHost > now ? Int(Double(command.startHost &- now) * framesPerTick) : 0
        // Strikes overlap at equal power: each new one makes room for what is still ringing, by as
        // much as is ringing, so a flurry stays as loud as one key instead of piling up.
        let room = 1 / (1 + ringing(Int(command.slot) < firstPreviewSlot ? 0..<firstPreviewSlot : firstPreviewSlot..<voiceCount)).squareRoot()
        let length = max(2, Int(command.length))
        let hold = length / 12
        let w = 2 * Double.pi * Double(command.bodyHz) / SoundBank.rate
        let r = exp(-1 / (Self.bodyDamping * SoundBank.rate))
        voices[Int(command.slot)] = Voice(active: true, left: command.sample.left, right: command.sample.right, frames: command.sample.frames,
                                          position: 0, step: Double(command.step), gainLeft: command.gainLeft * room, gainRight: command.gainRight * room,
                                          delayLeft: Int(command.delayLeft), delayRight: Int(command.delayRight),
                                          softness: command.softness, wait: wait, length: length, hold: hold,
                                          decay: Float(pow(Self.ringFloor, 1 / Double(length - hold))),
                                          bodyA: Float(2 * r * cos(w)), bodyB: Float(-r * r),
                                          bodyDrive: command.bodyDrive * Float(sin(w)) * Self.bodyLevel)
    }

    /// Catmull-Rom, the frames outside the sample being silence.
    @inline(__always)
    private static func read(_ p: UnsafePointer<Float>, _ frames: Int, _ at: Double) -> Float {
        guard at > -1 else { return 0 }
        let whole = at.rounded(.down)
        let i = Int(whole)
        guard i < frames else { return 0 }
        let t = Float(at - whole)
        let a = i >= 1 ? p[i - 1] : 0, b = i >= 0 ? p[i] : 0, c = i + 1 < frames ? p[i + 1] : 0, d = i + 2 < frames ? p[i + 2] : 0
        return b + 0.5 * t * (c - a + t * (2 * a - 5 * b + 4 * c - d + t * (3 * (b - c) + d - a)))
    }

    /// Adds `count` frames of one voice to the output. With `right` nil it adds the mono sum.
    @inline(__always)
    private func play(_ v: UnsafeMutablePointer<Voice>, count: Int, left out: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>?) {
        guard let left = v.pointee.left, let right = v.pointee.right else { v.pointee.active = false; return }
        let frames = v.pointee.frames, step = v.pointee.step
        let softness = v.pointee.softness, a = Self.softCoefficient
        var i = 0
        if v.pointee.wait > 0 {
            i = min(count, v.pointee.wait)
            v.pointee.wait -= i
        }
        let dl = Double(v.pointee.delayLeft), dr = Double(v.pointee.delayRight)
        while i < count {
            guard v.pointee.fade != 0 else { v.pointee.active = false; return }
            guard v.pointee.played < v.pointee.length else { v.pointee.active = false; return }
            if v.pointee.played >= v.pointee.hold { v.pointee.ring *= v.pointee.decay }
            var l = Self.read(left, frames, v.pointee.position - dl), r = Self.read(right, frames, v.pointee.position - dr)
            if softness > 0 {
                v.pointee.lowLeft = (1 - a) * l + a * v.pointee.lowLeft
                v.pointee.lowRight = (1 - a) * r + a * v.pointee.lowRight
                l -= softness * (l - v.pointee.lowLeft)
                r -= softness * (r - v.pointee.lowRight)
            }
            // The case hears the strike at its unfiltered level, and fades out with the voice.
            let hit = 0.5 * (l + r)
            let resonance = v.pointee.bodyA * v.pointee.body1 + v.pointee.bodyB * v.pointee.body2 + hit
            v.pointee.body2 = v.pointee.body1
            v.pointee.body1 = resonance
            let left = 1 - Float(v.pointee.played) / Float(v.pointee.length)
            let body = resonance * v.pointee.bodyDrive * left / max(v.pointee.ring, 0.01)
            l += body
            r += body
            var gain = v.pointee.ring
            if v.pointee.fade > 0 {
                gain *= Float(v.pointee.fade) / Float(v.pointee.fadeLength)
                v.pointee.fade -= 1
            }
            if let outRight {
                out[i] += l * v.pointee.gainLeft * gain
                outRight[i] += r * v.pointee.gainRight * gain
            } else {
                out[i] += 0.5 * (l + r) * v.pointee.gainLeft * gain
            }
            v.pointee.position += step
            v.pointee.played += 1
            i += 1
        }
    }

    /// The stereo block: every voice, mixed. Full-level overlaps ease into the ceiling instead of clipping.
    func renderStereo(count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        guard directPath.load(ordering: .relaxed) else { return false }
        take()
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        var sounding = false
        for i in 0..<voiceCount where voices[i].active {
            sounding = true
            play(voices + i, count: count, left: left, right: right)
        }
        guard sounding else { return false }
        for i in 0..<count {
            left[i] = Self.ceiling(left[i])
            right[i] = Self.ceiling(right[i])
        }
        return true
    }

    /// One voice's block on the HRTF path.
    func renderVoice(_ slot: Int, count: Int, out: UnsafeMutablePointer<Float>) -> Bool {
        guard !directPath.load(ordering: .relaxed) else { return false }
        take()
        guard voices[slot].active else { return false }
        out.update(repeating: 0, count: count)
        play(voices + slot, count: count, left: out, right: nil)
        return true
    }

    /// Linear to 0.9, then a smooth bend that never passes 1.
    @inline(__always)
    static func ceiling(_ x: Float) -> Float {
        let size = abs(x)
        guard size > 0.9 else { return x }
        let over = (size - 0.9) / 0.1
        let bent = 0.9 + 0.1 * over / (1 + over)
        return x < 0 ? -bent : bent
    }
}
