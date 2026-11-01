import AVFAudio
import Foundation

/// One profile's samples, decoded once into stereo float memory at the engine rate, with the stabilizer
/// rattle baked in. Pitch and tone are applied while a voice reads a sample, so the bank holds one copy of
/// each recording. Immutable after loading, so any thread may read it.
final class SoundBank: @unchecked Sendable {
    enum LoadError: Error, Equatable {
        case missing(Profile)
        case unreadable(Profile)

        var message: String {
            switch self {
            case .missing(let p): return "The \(p.title) sounds are missing. Reinstall Switchtone."
            case .unreadable(let p): return "The \(p.title) sounds could not be read. Reinstall Switchtone."
            }
        }
    }

    static let rate = 48_000.0
    /// Read speeds, like keys of slightly different mass. Index 2 is the recorded pitch.
    static let pitchSteps: [Float] = [0.965, 0.985, 1.0, 1.015, 1.035]
    /// A soft strike: the content above this corner drops by about 6 dB, the body stays.
    static let softCorner = 1_800.0
    static let softAmount: Float = 0.5

    /// One recorded strike: its two channels, of equal length, in the bank's own memory.
    struct Sample: @unchecked Sendable {
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var frames: Int
    }

    let profile: Profile
    /// Sample lists by class and direction, in fixed slots, so the key path never builds a string or
    /// searches a dictionary.
    private let samples: UnsafeMutablePointer<Sample>
    private let table: [(start: Int, count: Int)]
    private let memory: UnsafeMutablePointer<Float>
    let frameCount: Int

    private static func index(_ keyClass: KeyClass, down: Bool) -> Int { keyClass.index * 2 + (down ? 1 : 0) }

    /// `families` maps "space-down" to its recordings, each as (left, right) of equal length.
    init(profile: Profile, families: [String: [(left: [Float], right: [Float])]]) {
        self.profile = profile
        var total = 0
        var count = 0
        for recordings in families.values {
            count += recordings.count
            total += recordings.reduce(0) { $0 + $1.left.count }
        }
        frameCount = total
        memory = .allocate(capacity: max(1, total * 2))
        samples = .allocate(capacity: max(1, count))
        var entries = [(start: Int, count: Int)](repeating: (0, 0), count: KeyClass.allCases.count * 2)
        var nextSample = 0, nextFrame = 0
        for keyClass in KeyClass.allCases {
            for down in [false, true] {
                let family = "\(keyClass.rawValue)-\(down ? "down" : "up")"
                guard let recordings = families[family] else { continue }
                entries[Self.index(keyClass, down: down)] = (nextSample, recordings.count)
                for recording in recordings {
                    let frames = recording.left.count
                    let left = memory + nextFrame * 2, right = left + frames
                    recording.left.withUnsafeBufferPointer { if let base = $0.baseAddress { left.update(from: base, count: frames) } }
                    recording.right.withUnsafeBufferPointer { if let base = $0.baseAddress { right.update(from: base, count: frames) } }
                    (samples + nextSample).initialize(to: Sample(left: UnsafePointer(left), right: UnsafePointer(right), frames: frames))
                    nextSample += 1
                    nextFrame += frames
                }
            }
        }
        table = entries
    }

    deinit {
        memory.deallocate()
        samples.deallocate()
    }

    /// The bytes the samples take.
    var byteCount: Int { frameCount * 2 * MemoryLayout<Float>.size }

    /// The recordings for a class and direction, falling back to plain keys. Allocates nothing.
    func variants(_ keyClass: KeyClass, down: Bool) -> UnsafeBufferPointer<Sample>? {
        var entry = table[Self.index(keyClass, down: down)]
        if entry.count == 0 { entry = table[Self.index(.key, down: down)] }
        guard entry.count > 0 else { return nil }
        return UnsafeBufferPointer(start: samples + entry.start, count: entry.count)
    }

    // MARK: Loading

    /// Loads a profile from `Sounds/<profile>` in the given resource folder.
    static func load(_ profile: Profile, from resources: URL?) throws(LoadError) -> SoundBank {
        guard let dir = resources?.appendingPathComponent("Sounds/\(profile.rawValue)", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { throw .missing(profile) }

        var raw: [String: [(index: Int, left: [Float], right: [Float])]] = [:]
        for url in files where url.pathExtension.lowercased() == "wav" {
            // file names look like "space-down-3.wav"
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 3, let index = Int(parts[2]), let audio = readStereo(url) else { continue }
            let trimmed = trimLeadingSilence(left: audio.left, right: audio.right, rate: rate)
            raw["\(parts[0])-\(parts[1])", default: []].append((index, trimmed.left, trimmed.right))
        }
        guard raw["key-down"]?.isEmpty == false else { throw .unreadable(profile) }
        // Shift is a modifier on a stabilizer.
        if let down = raw["modifier-down"] { raw["shift-down"] = down }
        if let up = raw["modifier-up"] { raw["shift-up"] = up }

        var families: [String: [(left: [Float], right: [Float])]] = [:]
        for (family, recordings) in raw {
            let name = family.split(separator: "-").first.map(String.init) ?? ""
            let stabilized = KeyClass(rawValue: name)?.isStabilized ?? false
            let level: Float = family.hasSuffix("-down") ? 1 : 0.6
            families[family] = recordings.sorted { $0.index < $1.index }.map { entry in
                guard stabilized else { return (entry.left, entry.right) }
                let seed = UInt64(truncatingIfNeeded: family.hashValueStable &+ entry.index &* 7919)
                let left = addRattle(entry.left, rate: rate, seed: seed, level: level)
                // The same ticks on both channels: the two stay equally long and the stereo is the recording's.
                let right = addRattle(entry.right, rate: rate, seed: seed, level: level, length: left.count)
                return (left, right)
            }
        }
        return SoundBank(profile: profile, families: families)
    }

    /// Both channels of a file at the engine rate. A mono file gives two equal channels.
    static func readStereo(_ url: URL) -> (left: [Float], right: [Float])? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 1, file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData
        else { return nil }
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: frames)) : left
        let sourceRate = file.processingFormat.sampleRate
        return sourceRate == rate ? (left, right) : (resample(left, factor: 1, sourceRate: sourceRate), resample(right, factor: 1, sourceRate: sourceRate))
    }

    /// Cuts both channels at the same frame, so the stereo stays aligned.
    static func trimLeadingSilence(left: [Float], right: [Float], rate: Double) -> (left: [Float], right: [Float]) {
        let trimmedLeft = trimLeadingSilence(left, rate: rate), cut = left.count - trimmedLeft.count
        guard cut > 0 else { return (left, right) }
        var trimmedRight = Array(right[cut...])
        let fade = min(trimmedRight.count, Int(rate * 0.0003))
        for i in 0..<fade { trimmedRight[i] *= Float(i) / Float(fade) }
        return (trimmedLeft, trimmedRight)
    }

    /// Anything in front of the hit reads as lag. Start each sample 0.5 ms before its first transient
    /// (10% of peak) with a short fade-in so the cut never clicks.
    static func trimLeadingSilence(_ samples: [Float], rate: Double) -> [Float] {
        guard let peak = samples.lazy.map({ abs($0) }).max(), peak > 0,
              let onset = samples.firstIndex(where: { abs($0) >= peak * 0.1 })
        else { return samples }
        let start = max(0, onset - Int(rate * 0.0005))
        guard start > 0 else { return samples }
        var trimmed = Array(samples[start...])
        let fade = min(trimmed.count, Int(rate * 0.0003))
        for i in 0..<fade { trimmed[i] *= Float(i) / Float(fade) }
        return trimmed
    }

    /// Linear-interpolation resample. A factor above 1 plays higher and shorter, like a smaller key.
    static func resample(_ samples: [Float], factor: Double, sourceRate: Double = rate) -> [Float] {
        let step = sourceRate / rate * factor
        guard samples.count > 1, step > 0 else { return samples }
        let count = Int(Double(samples.count - 1) / step)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { src in
            for i in 0..<count {
                let position = Double(i) * step
                let index = Int(position)
                let fraction = Float(position - Double(index))
                out[i] = src[index] + (src[index + 1] - src[index]) * fraction
            }
        }
        return out
    }

    /// The same strike pressed gently: the content above `softCorner` drops by about 6 dB (half of a
    /// one-pole high band removed), the body stays. A voice does this while it reads; this is the same
    /// filter in one piece.
    static func soften(_ samples: [Float], rate: Double) -> [Float] {
        let a = Float(exp(-2 * Double.pi * softCorner / rate))
        var low: Float = 0
        return samples.map { x in
            low = (1 - a) * x + a * low
            return x - softAmount * (x - low)
        }
    }

    /// A wire stabilizer rattles: as the long key lands, the wire ends knock in
    /// their housings a few milliseconds after the main hit. Adds three short,
    /// bright, decaying ticks 6.5 to 22 ms after the onset, 10 to 21 dB under
    /// the peak, with timing and pitch that differ per sample.
    /// `length` pins the result to a length, for the second channel of a stereo sample.
    static func addRattle(_ samples: [Float], rate: Double, seed: UInt64, level: Float = 1, length: Int? = nil) -> [Float] {
        guard let peak = samples.lazy.map({ abs($0) }).max(), peak > 0 else {
            if let length, length > samples.count { return samples + [Float](repeating: 0, count: length - samples.count) }
            return samples
        }
        var rng = SplitMix64(seed: seed)
        let ticks: [(ClosedRange<Float>, Float)] = [(0.0065...0.009, -10), (0.012...0.015, -15), (0.018...0.022, -21)]
        let ringLength = Int(rate * 0.006)
        var out = samples + [Float](repeating: 0, count: Int(rate * 0.026))
        for (delayRange, db) in ticks {
            let start = Int(Double(rng.float(in: delayRange)) * rate)
            let frequency = Double(rng.float(in: 3_400...6_000))
            let gain = peak * powf(10, db / 20) * level
            let decay = rate * Double(rng.float(in: 0.0012...0.0022))
            for i in 0..<ringLength where start + i < out.count {
                let t = Double(i)
                let attack = min(1, t / (rate * 0.0002))
                let ring = sin(2 * .pi * frequency * t / rate) * exp(-t / decay) * attack
                let grit = Double(rng.float(in: -0.25...0.25)) * exp(-t / (decay * 0.5))
                out[start + i] += gain * Float(ring + grit)
            }
        }
        if let length {
            if out.count > length { out.removeSubrange(length...) }
            else if out.count < length { out += [Float](repeating: 0, count: length - out.count) }
            return out
        }
        // Drop the silent padding again, keeping the rattle's tail and never the sample's own.
        if let last = out.lastIndex(where: { abs($0) > peak * 0.0005 }) {
            out.removeSubrange(max(samples.count, last + 1)...)
        }
        return out
    }
}

private extension String {
    /// A hash that is the same on every launch (Swift's hashValue is seeded per process).
    var hashValueStable: Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Int(truncatingIfNeeded: h)
    }
}
