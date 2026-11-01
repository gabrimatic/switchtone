// Builds the samples Switchtone ships from the source recordings listed in README.md.
//
//   swiftc -O scripts/make-sounds.swift -o /tmp/make-sounds -framework AVFoundation -framework Accelerate
//   /tmp/make-sounds <sources-dir> <out-dir>        # writes <out>/<profile>/<class>-<down|up>-<n>.wav
//   /tmp/make-sounds --analyze <dir> [<other-dir>]  # spectrum, stereo and attack per profile; two dirs print the gain
//
// <sources-dir> holds `keyboard_sound_dataset/{red,blue}/*.wav` and `399603-typing.wav`. Sources are
// only decoded, never run. Every step is deterministic, so a run reproduces the committed files.
//
// One stroke goes through: a clean cut of the press and its release from the recording, a minimum-phase
// voicing EQ, a body (three damped low modes rung by the stroke's own hit, so the low end starts with
// the transient and the transient itself is untouched), stereo (a mid signal that is the stroke, and a
// side signal of short reflections that starts about 1.9 ms after the hit and stays above 280 Hz, so the hit
// is the same in both channels and the two channels sum back to the stroke), a tail that fades into
// silence, and one gain for the press and its release, so they keep their recorded balance.
import AVFoundation
import Accelerate

let rate = 48_000.0
let ms = 48

// MARK: Audio IO

/// Reads a file as mono float at its own rate.
func readFile(_ url: URL) -> (samples: [Float], rate: Double)? {
    guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
          file.length > 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData
    else { return nil }
    let frames = Int(buffer.frameLength), count = Int(file.processingFormat.channelCount)
    var mono = [Float](repeating: 0, count: frames)
    for c in 0..<count { vDSP_vsma(channels[c], 1, [1 / Float(count)], mono, 1, &mono, 1, vDSP_Length(frames)) }
    return (mono, file.processingFormat.sampleRate)
}

/// Mastering-quality sample rate conversion to 48 kHz.
func to48k(_ x: [Float], from sourceRate: Double) -> [Float] {
    guard sourceRate != rate else { return x }
    let input = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
    let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let converter = AVAudioConverter(from: input, to: output)!
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
    converter.sampleRateConverterQuality = .max
    let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(x.count))!
    source.frameLength = source.frameCapacity
    x.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    let capacity = AVAudioFrameCount(Double(x.count) * rate / sourceRate) + 4096
    let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
    nonisolated(unsafe) var given = false
    nonisolated(unsafe) let held = source
    var error: NSError?
    _ = converter.convert(to: result, error: &error) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return held
    }
    precondition(error == nil, "sample rate conversion failed")
    return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
}

func write(_ left: [Float], _ right: [Float], to url: URL) {
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                   AVLinearPCMIsNonInterleaved: false]
    let file = try! AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = AVAudioFrameCount(left.count)
    left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
    right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
    try! file.write(from: buffer)
}

// MARK: Filters (all one-pass, so minimum phase: nothing rings before the hit)

struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float

    func run(_ x: [Float]) -> [Float] {
        var z1: Float = 0, z2: Float = 0
        return x.map { v in
            let y = b0 * v + z1
            z1 = b1 * v - a1 * y + z2
            z2 = b2 * v - a2 * y
            return y
        }
    }

    private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Biquad {
        Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    static func highPass(_ hz: Double, q: Double = 0.707) -> Biquad {
        let w = 2 * .pi * hz / rate, a = sin(w) / (2 * q), c = cos(w)
        return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + a, -2 * c, 1 - a)
    }

    static func lowPass(_ hz: Double, q: Double = 0.707) -> Biquad {
        let w = 2 * .pi * hz / rate, a = sin(w) / (2 * q), c = cos(w)
        return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + a, -2 * c, 1 - a)
    }

    static func peak(_ hz: Double, db: Double, q: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * .pi * hz / rate, a = sin(w) / (2 * q), c = cos(w)
        return make(1 + a * A, -2 * c, 1 - a * A, 1 + a / A, -2 * c, 1 - a / A)
    }

    static func highShelf(_ hz: Double, db: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * .pi * hz / rate, s = sin(w), c = cos(w), r = 2 * A.squareRoot() * s / (2 * 0.707)
        return make(A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r),
                    (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r)
    }
}

// MARK: A small deterministic generator, so a run reproduces the files

struct Random {
    var state: UInt64
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func around(_ value: Double, by share: Double) -> Double { value * (1 + (unit() * 2 - 1) * share) }
}

// MARK: Measures

func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    var r: Float = 0
    Array(x).withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length(x.count)) }
    return r
}

func peak(_ x: [Float]) -> Float {
    guard !x.isEmpty else { return 0 }
    var m: Float = 0
    vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
    return m
}

/// Power spectrum of a zero-padded, one-sided Hann-tapered stroke: the attack keeps full weight.
func powerSpectrum(_ x: [Float], size: Int = 16_384) -> [Double] {
    var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
    let n = min(size, x.count)
    for i in 0..<n { re[i] = x[i] * (0.5 + 0.5 * cos(.pi * Float(i) / Float(n))) }
    let dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    defer { vDSP_DFT_DestroySetup(dft) }
    var outRe = [Float](repeating: 0, count: size), outIm = [Float](repeating: 0, count: size)
    vDSP_DFT_Execute(dft, re, im, &outRe, &outIm)
    return (0..<(size / 2)).map { Double(outRe[$0] * outRe[$0] + outIm[$0] * outIm[$0]) }
}

let bands: [(lo: Double, hi: Double)] = [(40, 120), (120, 300), (300, 1_000), (1_000, 4_000), (4_000, 10_000), (10_000, 16_000), (16_000, 20_000)]

func bandPower(_ spectrum: [Double], size: Int = 16_384) -> [Double] {
    let bin = rate / Double(size)
    return bands.map { band in
        var sum = 0.0
        for k in Int(band.lo / bin)..<min(spectrum.count, Int(band.hi / bin)) { sum += spectrum[k] }
        return sum
    }
}

func flatness(_ x: [Float]) -> Double {
    let s = powerSpectrum(x, size: 4_096).dropFirst(8).map { $0 + 1e-12 }
    let logMean = s.reduce(0) { $0 + log($1) } / Double(s.count)
    return exp(logMean) / (s.reduce(0, +) / Double(s.count))
}

func centroid(_ x: [Float]) -> Double {
    let s = powerSpectrum(x, size: 4_096)
    let bin = rate / 4_096
    let total = s.reduce(0, +)
    return s.enumerated().reduce(0) { $0 + Double($1.offset) * bin * $1.element } / max(total, 1e-12)
}

// MARK: Finding strokes

let hop = 96    // 2 ms

func envelope(_ x: [Float]) -> [Float] {
    stride(from: 0, to: x.count - hop, by: hop).map { i in
        var m: Float = 0
        x[i..<(i + hop)].withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &m, vDSP_Length(hop)) }
        return m
    }
}

/// Where a hit starts: the first sample above 8% of its peak, looking back no further than `reach`. A press
/// whose loudest moment comes late sounds late, so the finger's touch on the cap before the bottom-out is
/// left out: the sample starts on the hit.
func onset(_ x: [Float], peakAt: Int, reach: Int) -> Int {
    let level = abs(x[peakAt]) * 0.08
    var start = peakAt
    var i = peakAt
    while i > 0, peakAt - i < reach {
        i -= 1
        if abs(x[i]) >= level { start = i }
    }
    return start
}

func strongestPeak(_ x: [Float], from a: Int, to b: Int) -> (at: Int, level: Float) {
    var best = max(0, a), level: Float = 0
    for i in max(0, a)..<min(x.count, b) where abs(x[i]) > level { level = abs(x[i]); best = i }
    return (best, level)
}

struct Stroke { var down: [Float]; var up: [Float] }

/// Samples kept in front of a hit, for the fade-in.
let pre = 12

/// The labelled clips: 250 ms, the press at about 54 ms, the release after it. A clipped clip is dropped.
func clipStroke(_ x: [Float], reach: Int) -> Stroke? {
    guard !x.contains(where: { abs($0) >= 0.998 }) else { return nil }
    let press = strongestPeak(x, from: 30 * ms, to: 80 * ms)
    guard press.level > 0.12 else { return nil }
    let release = strongestPeak(x, from: press.at + 45 * ms, to: x.count - 30 * ms)
    guard release.level > press.level * 0.05 else { return nil }
    // Nothing else may be louder than the release between the two: that is a second press.
    let start = onset(x, peakAt: press.at, reach: reach), upStart = onset(x, peakAt: release.at, reach: reach)
    guard upStart - start > 38 * ms, start > 3 * ms else { return nil }
    return Stroke(down: Array(x[(start - pre)..<(upStart - pre)]), up: Array(x[(upStart - pre)...]))
}

/// A long take: a press is an event that stands clear of what came before it, followed by its release
/// and then silence, so the tails are clean.
func takeStrokes(_ x: [Float], reach: Int) -> [Stroke] {
    let env = envelope(x)
    let sorted = env.sorted()
    let floorLevel = sorted[sorted.count / 10] * 3
    let eventLevel = sorted[sorted.count * 995 / 1000]
    var events: [Int] = []
    var i = 0
    while i < env.count {
        if env[i] > eventLevel * 0.3 {
            var top = i
            for j in i..<min(env.count, i + 8) where env[j] > env[top] { top = j }
            events.append(top * hop)
            i = top + 12
        } else { i += 1 }
    }
    var strokes: [Stroke] = []
    for k in 1..<(events.count - 2) {
        let previous = events[k - 1], press = events[k], release = events[k + 1], next = events[k + 2]
        guard press - previous > 180 * ms, release - press > 45 * ms, release - press < 180 * ms, next - release > 160 * ms else { continue }
        // Quiet in front of the press, and no unnoticed event around the release.
        guard press > 40 * ms, press + 300 * ms < x.count, rms(x[(press - 40 * ms)..<(press - 10 * ms)]) < floorLevel else { continue }
        let peakDown = strongestPeak(x, from: press - 6 * ms, to: press + 6 * ms)
        let peakUp = strongestPeak(x, from: release - 6 * ms, to: release + 6 * ms)
        guard peakDown.level < 0.95, peakUp.level > peakDown.level * 0.06 else { continue }
        let start = onset(x, peakAt: peakDown.at, reach: reach), upStart = onset(x, peakAt: peakUp.at, reach: reach)
        strokes.append(Stroke(down: Array(x[(start - pre)..<(upStart - pre)]),
                              up: Array(x[(upStart - pre)..<min(x.count, upStart + 150 * ms)])))
    }
    return strokes
}

// MARK: Voicing

struct Mode { var hz: Double; var decay: Double; var level: Float }

struct Voicing {
    var eq: [Biquad]
    /// The damped low modes the hit rings, relative to the stroke's peak.
    var modes: [Mode]
    /// Side level against mid.
    var width: Float
    /// Key press loudness: RMS of the first 40 ms.
    var loudness: Float
}

/// Rings the modes with the first milliseconds of the stroke. The modes start with the hit, on the same sample.
func body(_ x: [Float], modes: [Mode], peakLevel: Float, random: inout Random) -> [Float] {
    let excite = Biquad.lowPass(900).run(Array(x.prefix(4 * ms)) + [Float](repeating: 0, count: x.count))
    var out = [Float](repeating: 0, count: x.count)
    for mode in modes {
        let hz = random.around(mode.hz, by: 0.05)
        let r = exp(-1 / (mode.decay * rate)), w = 2 * Double.pi * hz / rate
        let a1 = Float(2 * r * cos(w)), a2 = Float(-r * r)
        var y1: Float = 0, y2: Float = 0
        var ring = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let y = (i < excite.count ? excite[i] : 0) + a1 * y1 + a2 * y2
            ring[i] = y
            y2 = y1
            y1 = y
        }
        let scale = mode.level * peakLevel / max(peak(ring), 1e-9)
        vDSP_vsma(ring, 1, [scale], out, 1, &out, 1, vDSP_Length(x.count))
    }
    return out
}

/// The side signal: short reflections of the stroke above 280 Hz. The first comes about 1.9 ms after the hit.
func side(_ x: [Float], width: Float, random: inout Random) -> [Float] {
    let reflections: [(ms: Double, gain: Float)] = [(1.9, 0.62), (3.1, -0.54), (4.7, 0.47), (7.3, -0.40), (10.9, 0.32), (15.7, -0.25), (22.3, 0.16), (31.1, -0.10)]
    let source = Biquad.lowPass(11_000).run(Biquad.highPass(280, q: 0.6).run(x))
    var out = [Float](repeating: 0, count: x.count)
    for r in reflections {
        let delay = Int(random.around(r.ms, by: 0.12) * 48)
        guard delay < x.count else { continue }
        let gain = r.gain * Float(random.around(1, by: 0.2)) * width
        for i in delay..<x.count { out[i] += gain * source[i - delay] }
    }
    return out
}

/// Fades the tail into silence, so a stroke never ends on room noise.
func fadedTail(_ x: [Float], hold: Int, tau: Double, length: Int) -> [Float] {
    var y = Array(x.prefix(length))
    for i in 0..<y.count where i > hold { y[i] *= Float(exp(-Double(i - hold) / (tau * rate))) }
    let end = min(y.count, 96)
    for i in 0..<end { y[y.count - 1 - i] *= Float(i) / Float(end) }
    return y
}

struct Master { var downL: [Float]; var downR: [Float]; var upL: [Float]; var upR: [Float] }

/// A sinc resample for the bigger keys: below 1 the stroke plays lower and longer.
func pitched(_ x: [Float], _ factor: Double) -> [Float] {
    let taps = 16, count = Int(Double(x.count - 1) / factor)
    return (0..<count).map { n in
        let p = Double(n) * factor, k = Int(p)
        var sum = 0.0
        for j in (k - taps + 1)...(k + taps) where j >= 0 && j < x.count {
            let d = p - Double(j)
            let s = d == 0 ? 1 : sin(.pi * d * min(1, factor)) / (.pi * d)
            let w = 0.5 + 0.5 * cos(.pi * d / Double(taps))
            sum += Double(x[j]) * s * w
        }
        return Float(sum)
    }
}

func master(_ stroke: Stroke, _ voicing: Voicing, seed: UInt64, extraDB: Float = 0, bodyGain: Float = 1) -> Master {
    var random = Random(state: seed)
    func prepare(_ x: [Float], modes: [Mode]) -> [Float] {
        var y = Biquad.highPass(38).run(x)
        for filter in voicing.eq { y = filter.run(y) }
        let ring = body(y, modes: modes, peakLevel: peak(y), random: &random)
        vDSP_vadd(y, 1, ring, 1, &y, 1, vDSP_Length(y.count))
        return y
    }
    let modes = voicing.modes.map { Mode(hz: $0.hz, decay: $0.decay, level: $0.level * bodyGain) }
    let down = prepare(stroke.down, modes: modes)
    // A release is lighter: the cap comes back up against the stem, it does not ring the case as much.
    let up = prepare(stroke.up, modes: modes.map { Mode(hz: $0.hz * 1.15, decay: $0.decay * 0.7, level: $0.level * 0.45) })
    let gain0 = voicing.loudness * pow(10, extraDB / 20) / max(rms(down.prefix(40 * ms)), 1e-6)

    func stereo(_ m: [Float], hold: Int, tau: Double, length: Int) -> ([Float], [Float]) {
        let s = side(m, width: voicing.width, random: &random)
        var l = [Float](repeating: 0, count: m.count), r = l
        vDSP_vadd(m, 1, s, 1, &l, 1, vDSP_Length(m.count))
        vDSP_vsub(s, 1, m, 1, &r, 1, vDSP_Length(m.count))
        return (fadedTail(l, hold: hold, tau: tau, length: length), fadedTail(r, hold: hold, tau: tau, length: length))
    }
    var (dl, dr) = stereo(down, hold: 34 * ms, tau: 0.030, length: min(down.count, 170 * ms))
    var (ul, ur) = stereo(up, hold: 22 * ms, tau: 0.022, length: min(up.count, 120 * ms))
    let top = max(peak(dl), peak(dr), peak(ul), peak(ur))
    let gain = min(gain0, 0.79 / max(top, 1e-6))   // -2 dBFS
    for i in dl.indices { dl[i] *= gain; dr[i] *= gain }
    for i in ul.indices { ul[i] *= gain; ur[i] *= gain }
    return Master(downL: dl, downR: dr, upL: ul, upR: ur)
}

// MARK: Profiles

// The reds and the blues were recorded with a good low end: their voicing only leans on it. The take is
// bright and light, so it gets most of its body here. Levels are against the stroke's own peak.
let linear = Voicing(eq: [.peak(2_400, db: -1.5, q: 0.8), .highShelf(11_000, db: -1)],
                     modes: [Mode(hz: 142, decay: 0.018, level: 0.08), Mode(hz: 198, decay: 0.014, level: 0.07), Mode(hz: 274, decay: 0.011, level: 0.05)],
                     width: 0.44, loudness: 0.086)
let tactile = Voicing(eq: [.peak(190, db: 5, q: 0.7), .peak(440, db: 2.5, q: 1.0), .peak(3_100, db: -2, q: 0.9), .highShelf(10_000, db: -3)],
                      modes: [Mode(hz: 128, decay: 0.022, level: 0.20), Mode(hz: 176, decay: 0.018, level: 0.18), Mode(hz: 248, decay: 0.014, level: 0.13)],
                      width: 0.44, loudness: 0.086)
let clicky = Voicing(eq: [.peak(200, db: 1.5, q: 0.8), .peak(3_200, db: 2.5, q: 0.9), .highShelf(11_000, db: -4.5)],
                     modes: [Mode(hz: 156, decay: 0.014, level: 0.07), Mode(hz: 226, decay: 0.011, level: 0.06), Mode(hz: 296, decay: 0.009, level: 0.05)],
                     width: 0.48, loudness: 0.086)

// MARK: Building a profile

func pick(_ pool: [Stroke], count: Int) -> [Stroke] {
    // Noise-like cuts go first, then the strokes spread from dark to bright, so the set has real variety.
    let clean = pool.filter { flatness($0.down) < 0.32 && $0.down.count >= 40 * ms && $0.up.count >= 28 * ms }
    precondition(clean.count >= count, "only \(clean.count) clean strokes")
    let ranked = clean.sorted { centroid($0.down) < centroid($1.down) }
    return (0..<count).map { ranked[$0 * ranked.count / count] }
}

func build(_ name: String, pool: [Stroke], voicing: Voicing, into root: URL) {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let keys = pick(pool, count: 16)
    let seed = UInt64(name.utf8.reduce(7) { ($0 &* 131) &+ Int($1) })
    func emit(_ family: String, _ strokes: [Stroke], factor: Double = 1, extraDB: Float = 0, bodyGain: Float = 1) {
        for (n, stroke) in strokes.enumerated() {
            let shifted = factor == 1 ? stroke : Stroke(down: pitched(stroke.down, factor), up: pitched(stroke.up, factor))
            let m = master(shifted, voicing, seed: seed &+ UInt64(family.utf8.count * 100 + n), extraDB: extraDB, bodyGain: bodyGain)
            write(m.downL, m.downR, to: dir.appendingPathComponent("\(family)-down-\(n + 1).wav"))
            write(m.upL, m.upR, to: dir.appendingPathComponent("\(family)-up-\(n + 1).wav"))
        }
    }
    emit("key", keys)
    // Bigger keys are lower and heavier: they come from the darkest strokes.
    emit("space", Array(keys.prefix(4)), factor: 0.78, extraDB: 1.5, bodyGain: 1.5)
    emit("enter", Array(keys.dropFirst(1).prefix(3)), factor: 0.85, extraDB: 1, bodyGain: 1.3)
    emit("backspace", Array(keys.dropFirst(3).prefix(3)), factor: 0.90, extraDB: 0.5, bodyGain: 1.15)
    emit("modifier", Array(keys.dropFirst(8).prefix(3)), factor: 0.95, extraDB: -2)
    print("\(name): \(pool.count) strokes found, 16 keys and 13 big keys written")
}

// MARK: Analysis

struct Summary {
    var bands: [Double]      // dB share of the press
    var body: Double         // absolute 120–300 Hz level, dBFS-like, per press
    var length: Double       // ms
    var correlation: Double  // left to right, first 60 ms
    var attack: Double       // ms from 10% to 90% of the first peak
    var crest: Double
    var channels: Int
}

func readStereo(_ url: URL) -> (l: [Float], r: [Float])? {
    guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
    let n = Int(buffer.frameLength)
    let l = Array(UnsafeBufferPointer(start: data[0], count: n))
    let r = file.processingFormat.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : l
    return (l, r)
}

func analyze(_ dir: URL) -> [String: Summary] {
    var out: [String: Summary] = [:]
    for profile in ["linear", "tactile", "clicky"] {
        let folder = dir.appendingPathComponent(profile)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
        let presses = files.filter { $0.lastPathComponent.hasPrefix("key-down") }
        var power = [Double](repeating: 0, count: bands.count), lengths = 0.0, corr = 0.0, attack = 0.0, crest = 0.0, channels = 1
        for url in presses {
            guard let (l, r) = readStereo(url) else { continue }
            let mid = zip(l, r).map { ($0 + $1) / 2 }
            if l != r { channels = 2 }
            let p = bandPower(powerSpectrum(mid))
            for i in power.indices { power[i] += p[i] }
            lengths += Double(l.count) / 48
            let n = min(l.count, 60 * ms)
            var ab: Float = 0, aa: Float = 0, bb: Float = 0
            vDSP_dotpr(l, 1, r, 1, &ab, vDSP_Length(n)); vDSP_dotpr(l, 1, l, 1, &aa, vDSP_Length(n)); vDSP_dotpr(r, 1, r, 1, &bb, vDSP_Length(n))
            corr += Double(ab / max((aa * bb).squareRoot(), 1e-12))
            let top = peak(mid)
            let at = mid.firstIndex { abs($0) >= top } ?? 0
            let a = mid.firstIndex { abs($0) >= top * 0.1 } ?? 0, b = mid.firstIndex { abs($0) >= top * 0.9 } ?? at
            attack += Double(b - a) / 48
            crest += Double(20 * log10(top / max(rms(mid[...]), 1e-9)))
        }
        let count = Double(presses.count), total = power.reduce(0, +)
        out[profile] = Summary(bands: power.map { 10 * log10($0 / total + 1e-15) }, body: 10 * log10(power[1] / count + 1e-15) ,
                               length: lengths / count, correlation: corr / count, attack: attack / count, crest: crest / count, channels: channels)
    }
    return out
}

func printSummary(_ s: [String: Summary], label: String) {
    print("\n\(label)")
    print("profile   " + bands.map { String(format: "%6.0f-%-5.0f", $0.lo, $0.hi) }.joined() + "  length  L/R corr  attack  crest  ch")
    for name in ["linear", "tactile", "clicky"] {
        guard let v = s[name] else { continue }
        print(name.padding(toLength: 10, withPad: " ", startingAt: 0) + v.bands.map { String(format: "%10.1f  ", $0) }.joined()
              + String(format: "  %4.0f ms   %.2f   %5.2f ms  %4.1f dB  %d", v.length, v.correlation, v.attack, v.crest, v.channels))
    }
}

// MARK: Main

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--analyze" {
    let first = analyze(URL(fileURLWithPath: args[2]))
    printSummary(first, label: "\(args[2]) (band share of the press, dB)")
    if args.count > 3 {
        let second = analyze(URL(fileURLWithPath: args[3]))
        printSummary(second, label: "\(args[3]) (band share of the press, dB)")
        print("\nSpectrum gain, second against first (band share, dB)")
        for name in ["linear", "tactile", "clicky"] {
            guard let a = first[name], let b = second[name] else { continue }
            print(name.padding(toLength: 10, withPad: " ", startingAt: 0) + zip(a.bands, b.bands).map { String(format: "%+10.1f  ", $1 - $0) }.joined())
        }
    }
    exit(0)
}
guard args.count == 3 else {
    print("usage: make-sounds <sources-dir> <out-dir> | --analyze <dir> [<other-dir>]")
    exit(2)
}

let sources = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])

func clips(_ folder: String, reach: Int) -> [Stroke] {
    let dir = sources.appendingPathComponent("keyboard_sound_dataset/\(folder)")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    // The file name is the clip's place in the original take. Neighbours are the same stroke cut twice.
    var seen: [Int] = []
    var strokes: [Stroke] = []
    for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let place = Int(url.deletingPathExtension().lastPathComponent) ?? 0
        guard !seen.contains(where: { abs($0 - place) < 22_050 }) else { continue }
        seen.append(place)
        guard let (x, r) = readFile(url), let stroke = clipStroke(to48k(x, from: r), reach: reach) else { continue }
        strokes.append(stroke)
    }
    return strokes
}

guard let (take, takeRate) = readFile(sources.appendingPathComponent("399603-typing.wav")) else { fatalError("missing 399603-typing.wav") }
// A blue switch's click comes a moment before its bottom-out and is the point of it, so that cut reaches further back.
build("linear", pool: clips("red", reach: 72), voicing: linear, into: out)
build("tactile", pool: takeStrokes(to48k(take, from: takeRate), reach: 72), voicing: tactile, into: out)
build("clicky", pool: clips("blue", reach: 144), voicing: clicky, into: out)
