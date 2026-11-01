import CoreAudio
import Foundation
import os

/// The current default output device and what kind of listening it means.
struct AudioRoute: Equatable, Sendable {
    var name: String
    var kind: OutputKind

    static let none = AudioRoute(name: "No output", kind: .none)

    /// Built-in jack data sources.
    static let headphoneSource: UInt32 = 0x6864_706E  // 'hdpn'
    static let internalSpeakerSource: UInt32 = 0x6973_706B  // 'ispk'

    /// Classifies a device from its transport, data source and name.
    ///
    /// Bluetooth is ambiguous at the Core Audio level: AirPods, Beats and most
    /// Bluetooth audio are worn, so Bluetooth counts as headphones unless the
    /// name says speaker, soundbar or HomePod.
    static func classify(transport: UInt32, dataSource: UInt32?, name: String) -> OutputKind {
        let lower = name.lowercased()
        let speakerWords = ["speaker", "soundbar", "homepod", "sonos", "display audio", "tv"]
        let wornWords = ["headphone", "headset", "airpods", "earpods", "buds", "beats", "earphone", "in-ear"]
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == headphoneSource ? .headphones : .builtInSpeakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return speakerWords.contains(where: lower.contains) ? .externalSpeakers : .headphones
        case kAudioDeviceTransportTypeUSB:
            return wornWords.contains(where: lower.contains) ? .headphones : .externalSpeakers
        default:
            return wornWords.contains(where: lower.contains) ? .headphones : .externalSpeakers
        }
    }

    /// Reads the default output device now.
    static func current() -> AudioRoute {
        guard let device = defaultOutputDevice() else { return .none }
        let transport: UInt32 = property(device, kAudioDevicePropertyTransportType) ?? 0
        let source: UInt32? = property(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let name = deviceName(device) ?? "Output"
        return AudioRoute(name: name, kind: classify(transport: transport, dataSource: source, name: name))
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id: AudioObjectID? = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// The part of the way to the listener that belongs to the output device, as Core Audio reports it: what
/// happens to a sample after Switchtone hands it over. On the built-in speakers most of this is the
/// system's own speaker processing, which no app can skip.
struct OutputPath: Equatable, Sendable {
    /// Frames, at `rate`.
    var device: UInt32
    var stream: UInt32
    var safety: UInt32
    var rate: Double

    /// Device and stream latency: from the hardware's clock to the sound leaving it.
    var hardwareMilliseconds: Double { Double(device + stream) / rate * 1000 }
    var safetyMilliseconds: Double { Double(safety) / rate * 1000 }

    var description: String {
        String(format: "device %u + stream %u frames (%.1f ms), safety %u frames (%.1f ms) at %.0f Hz",
               device, stream, hardwareMilliseconds, safety, safetyMilliseconds, rate)
    }

    /// Reads the default output device now. Nil when there is none.
    static func current() -> OutputPath? {
        guard let device = AudioRoute.defaultOutputDevice() else { return nil }
        let scope = kAudioObjectPropertyScopeOutput
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else { return nil }
        var stream = AudioStreamID(0)
        var one = UInt32(MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &one, &stream) == noErr else { return nil }
        let rate: Float64 = AudioRoute.property(device, kAudioDevicePropertyNominalSampleRate) ?? 48_000
        let deviceFrames: UInt32 = AudioRoute.property(device, kAudioDevicePropertyLatency, scope: scope) ?? 0
        let safety: UInt32 = AudioRoute.property(device, kAudioDevicePropertySafetyOffset, scope: scope) ?? 0
        let streamFrames: UInt32 = AudioRoute.property(stream, kAudioStreamPropertyLatency) ?? 0
        return OutputPath(device: deviceFrames, stream: streamFrames, safety: safety, rate: rate)
    }
}

/// Watches the default output device and, on the current device, its data
/// source (the headphone jack switches source without changing device).
final class AudioRouteMonitor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onChange: @Sendable (AudioRoute) -> Void
    private let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "route")
    // Touched only on `queue`.
    private var watchedDevice: AudioObjectID?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var sourceListener: AudioObjectPropertyListenerBlock?
    private var last: AudioRoute?

    init(queue: DispatchQueue, onChange: @escaping @Sendable (AudioRoute) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            var address = Self.defaultDeviceAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block) == noErr {
                defaultListener = block
            }
            refresh()
        }
    }

    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var dataSourceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Runs on `queue`.
    private func refresh() {
        let device = AudioRoute.defaultOutputDevice()
        if device != watchedDevice {
            if let old = watchedDevice, let block = sourceListener {
                var address = Self.dataSourceAddress
                AudioObjectRemovePropertyListenerBlock(old, &address, queue, block)
            }
            sourceListener = nil
            watchedDevice = device
            if let device {
                var address = Self.dataSourceAddress
                if AudioObjectHasProperty(device, &address) {
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
                    if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr { sourceListener = block }
                }
            }
        }
        let route = AudioRoute.current()
        guard route != last else { return }
        last = route
        log.info("output route: \(route.kind.rawValue, privacy: .public)")
        onChange(route)
    }
}
