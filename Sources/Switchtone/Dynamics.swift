import AVFAudio
import Darwin

/// mach_absolute_time conversions. The tap thread and the audio scheduler share this clock.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var now: UInt64 { mach_absolute_time() }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func seconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Nanoseconds since boot on the same clock CGEvent timestamps use.
    static var uptimeNanos: UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// A tiny deterministic generator. `Float.random` asks the kernel for entropy,
/// which has no place on the event-tap thread.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    mutating func index(below count: Int) -> Int {
        count <= 1 ? 0 : Int(next() % UInt64(count))
    }
}

/// How fast the typing is, from the rhythm of the presses, the way a real board answers it. A slow
/// press travels the whole way and lands hard: full level, full length, bright. Fast fingers barely
/// bottom out, so a key at full speed is half as loud, half as long and dark (the engine picks the
/// bright tone less often as the speed rises).
struct TypingDynamics: Sendable {
    /// Smoothed interval between presses, seconds.
    private(set) var interval: Double = 0.35
    private var lastPress: UInt64 = 0

    /// Full speed, about 110 words a minute.
    static let fastInterval = 0.11
    static let slowInterval = 0.3

    /// Feeds one key press and returns its speed, 0 (slow) to 1 (fast).
    mutating func press(at host: UInt64) -> Float {
        if lastPress != 0, host > lastPress {
            let gap = min(1.5, HostClock.seconds(ticks: host - lastPress))
            // A pause resets the feel quickly; steady typing settles over a few keys.
            let weight = gap > Self.slowInterval ? 0.6 : 0.5
            interval += (gap - interval) * weight
        }
        lastPress = host
        return intensity
    }

    var intensity: Float {
        let t = (Self.slowInterval - interval) / (Self.slowInterval - Self.fastInterval)
        return Float(min(1, max(0, t)))
    }

    /// Linear gain for a speed: full level slow, half at full speed.
    static func gain(_ intensity: Float) -> Float { 1 - 0.5 * intensity }

}

/// The case under the keys. Each spot on the board rings at its own low note, the long keys lowest,
/// and how hard the strike drives it follows the touch: a key landing slowly thuds, a fast one and a
/// release barely move it.
enum StrikeBody {
    static func note(keyCode: Int64, big: Bool) -> Float {
        let spread = Float(UInt64(bitPattern: keyCode &* 2_654_435_761) % 40)
        return (big ? 105 : 135) + spread
    }

    static func drive(speed: Float, press: Bool) -> Float {
        (press ? 1 : 0.35) * (1 - 0.5 * min(1, max(0, speed)))
    }
}

/// When a release should sound. A switch's contact opens as the key starts to
/// rise; the top-out click comes when the spring has carried the keycap back,
/// a few milliseconds later. A press is played at once because the MacBook key
/// under the finger bottoms out at that moment.
enum ReleaseTiming {
    /// Spring return delay range, seconds.
    static let springReturn: ClosedRange<Float> = 0.006...0.013
    /// A release never lands closer than this to its own press.
    static let minimumAfterPress = 0.022

    /// Delay from now for a release whose press played `sincePress` seconds ago.
    static func delay(sincePress: Double, spring: Float) -> Double {
        max(Double(spring), minimumAfterPress - sincePress)
    }
}

/// The virtual desk: the listener's head at the origin, facing -Z with +Y up,
/// and a MacBook keyboard on the desk in front and below. This is the HRTF path's scene.
enum SpatialScene {
    /// Centre-to-centre key pitch on a MacBook keyboard, metres.
    static let keyPitch: Float = 0.0185
    /// Ears above the keys, and keys in front of the ears, metres.
    static let height: Float = 0.30
    static let depth: Float = 0.40
    /// How much wider than life the keyboard is drawn on headphones: the HRTF resolves a real board's width
    /// only subtly, so the edge keys are drawn about 36 degrees out, where the ears clearly tell the sides apart.
    static let headphoneWidth: Float = 2.6

    static func position(column: Double, row: Double, width: Float = headphoneWidth) -> AVAudio3DPoint {
        let x = Float(StereoStage.spread(column: column) * StereoStage.sceneReach) * keyPitch * width
        let z = -depth + Float(row - KeyLayout.center.row) * keyPitch
        return AVAudio3DPoint(x: x, y: -height, z: z)
    }

    static func position(forKeyCode code: Int64, width: Float = headphoneWidth) -> AVAudio3DPoint {
        let spot = KeyLayout.spot(forKeyCode: code)
        return position(column: spot.column, row: spot.row, width: width)
    }

    /// Straight ahead, for previews.
    static var center: AVAudio3DPoint { position(column: KeyLayout.center.column, row: KeyLayout.center.row) }

    /// Distance from the ears to the keyboard centre: sounds there play at full level.
    static var referenceDistance: Float { (height * height + depth * depth).squareRoot() }
}

/// How one key plays on the direct path: a gain for each channel and how late each channel starts.
struct Placement: Equatable, Sendable {
    var gainLeft: Float
    var gainRight: Float
    var delayLeft: Int32
    var delayRight: Int32
}

/// Position on the direct path: a per-voice gain and a small inter-channel delay, with no 3D renderer
/// in the way. Mirror-image keys get mirror-image placements by construction, so the far right sits
/// exactly as far right as the far left sits left.
enum StereoStage {
    /// The middle of the stage is where the two hands meet, between F and J: the space bar's centre, half a
    /// column left of the keyboard's. The home row is a mirror image around it, so a right-hand key sits
    /// exactly as far right as the same finger's left-hand key sits left. Measured from the keyboard's own
    /// centre, the right hand sits a column closer in than the left, and reads as centred.
    static let middle = 6.75
    /// Out to here, on both sides, one column is the same step: the home row, A to the semicolon.
    static let evenReach = 4.5
    /// The share of the stage the even zone takes.
    static let evenShare = 0.72
    /// The outermost keys, Delete and the key left of 1, sit on the edge, so each side stretches to fit.
    static let leftEdgeColumn = 0.5
    static let rightEdgeColumn = 13.75
    /// How far out the edge is drawn in the HRTF scene, in columns.
    static let sceneReach = 6.5
    /// On speakers the edge keys sit this much louder in their own channel. The speakers flank the
    /// keyboard, so a far key really is next to its speaker.
    static let speakerEdgeDifference = 12.0
    /// The far channel of an edge key starts this much later, which pulls the image further to the near side.
    static let speakerEdgeDelay = 0.00035
    /// With 3D sound off the keys keep a gentle stereo position.
    static let plainEdgeDifference = 4.5

    enum Kind: Sendable { case speakers, plain }

    /// -1 at the far left, 1 at the far right. The keys under the fingers sit in the middle of the board, so the
    /// curve opens the middle up: a key three columns out is more than half way to the edge, and it is heard off centre.
    static func spread(column: Double) -> Double {
        let d = column - middle, a = abs(d)
        let reach = d < 0 ? middle - leftEdgeColumn : rightEdgeColumn - middle
        let linear = a <= evenReach ? a / evenReach * evenShare
            : min(1, evenShare + (a - evenReach) / (reach - evenReach) * (1 - evenShare))
        let curved = pow(linear, 0.75)
        return d < 0 ? -curved : curved
    }

    /// Equal power: the two gains' squares always add up to 2, so a key keeps its loudness wherever
    /// it sits and a centred key plays both channels at 1.
    static func placement(column: Double, row: Double, kind: Kind) -> Placement {
        let edge = kind == .speakers ? speakerEdgeDifference : plainEdgeDifference
        let delay = kind == .speakers ? speakerEdgeDelay : 0
        let quarter = Double.pi / 4
        let reach = 1 - atan(pow(10, -edge / 20)) / quarter
        let p = spread(column: column)
        let angle = quarter * (1 + p * reach)
        // Nearer rows are a touch louder, as on a desk: about 1 dB from the function row to the space bar.
        let z = Double(SpatialScene.depth) - (row - KeyLayout.center.row) * Double(SpatialScene.keyPitch)
        let distance = (Double(SpatialScene.height * SpatialScene.height) + z * z).squareRoot()
        let near = Double(SpatialScene.referenceDistance) / distance
        let frames = Int32((abs(p) * delay * SoundBank.rate).rounded())
        return Placement(gainLeft: Float(2.0.squareRoot() * cos(angle) * near), gainRight: Float(2.0.squareRoot() * sin(angle) * near),
                         delayLeft: p > 0 ? frames : 0, delayRight: p < 0 ? frames : 0)
    }

    static func placement(forKeyCode code: Int64, kind: Kind) -> Placement {
        let spot = KeyLayout.spot(forKeyCode: code)
        return placement(column: spot.column, row: spot.row, kind: kind)
    }

    private static func table(_ kind: Kind) -> [Placement] {
        (0..<128).map { placement(forKeyCode: Int64($0), kind: kind) }
    }

    /// Worked out once, so a keystroke only reads a table.
    private static let speakerTable = table(.speakers)
    private static let plainTable = table(.plain)

    /// Lock-free, allocates nothing.
    static func lookup(_ code: Int64, kind: Kind) -> Placement {
        let index = Int(code & 127)
        return kind == .speakers ? speakerTable[index] : plainTable[index]
    }
}

/// Where the sound goes, from the current output device.
enum OutputKind: String, Sendable, Equatable {
    case headphones, builtInSpeakers, externalSpeakers, none

    var environmentType: AVAudioEnvironmentOutputType {
        switch self {
        case .headphones: return .headphones
        case .builtInSpeakers: return .builtInSpeakers
        case .externalSpeakers, .none: return .externalSpeakers
        }
    }
}

/// Picks the rendering for the route, the 3D switch and the power state.
enum RenderPolicy {
    enum Path: Sendable { case stage, plain, spatial }

    struct Choice: Equatable, Sendable {
        var path: Path
        var algorithm: AVAudio3DMixingRenderingAlgorithm
        var outputType: AVAudioEnvironmentOutputType
        var headTracking: Bool

        var label: String {
            switch path {
            case .stage: return "stereo stage"
            case .plain: return "plain stereo"
            case .spatial: return algorithm.label
            }
        }
    }

    /// Speakers and external speakers play on the stereo stage. Headphones take the HRTF path when this
    /// output offers it, and the stereo stage when it does not.
    /// - Parameters:
    ///   - applicable: what the environment node supports on its current output format.
    ///   - economy: Low Power Mode or thermal pressure: the cheaper HRTF instead of HRTFHQ.
    static func choose(kind: OutputKind, spatial: Bool, headTracking: Bool, economy: Bool,
                       applicable: [AVAudio3DMixingRenderingAlgorithm]) -> Choice {
        guard spatial else {
            return Choice(path: .plain, algorithm: .equalPowerPanning, outputType: kind.environmentType, headTracking: false)
        }
        if kind == .headphones {
            let order: [AVAudio3DMixingRenderingAlgorithm] = economy ? [.HRTF, .HRTFHQ, .sphericalHead] : [.HRTFHQ, .HRTF, .sphericalHead]
            if let algorithm = order.first(where: applicable.contains) {
                return Choice(path: .spatial, algorithm: algorithm, outputType: .headphones, headTracking: headTracking)
            }
        }
        return Choice(path: .stage, algorithm: .equalPowerPanning, outputType: kind.environmentType, headTracking: false)
    }
}

extension AVAudio3DMixingRenderingAlgorithm {
    var label: String {
        switch self {
        case .equalPowerPanning: return "equal-power"
        case .sphericalHead: return "spherical-head"
        case .HRTF: return "HRTF"
        case .HRTFHQ: return "HRTFHQ"
        case .soundField: return "sound-field"
        case .stereoPassThrough: return "pass-through"
        case .auto: return "auto"
        @unknown default: return "unknown"
        }
    }
}
