import Darwin
import Foundation
import Synchronization
import os

/// What a tick needs from the hardware.
protocol TickActuator: Sendable {
    /// Gets the actuator ready. False when it cannot be used now.
    func open() -> Bool
    /// One tick. False when it failed.
    func tick() -> Bool
    func close()
}

/// The trackpad's actuator, through the private MultitouchSupport framework. It is loaded with `dlopen`, so
/// a macOS without it, or with its functions renamed, leaves Switchtone exactly as it was: `make` returns
/// nil and there is no tick. Each call goes to the trackpad's driver and takes about 4 ms, so it never
/// runs on the event tap's thread.
final class MultitouchActuator: TickActuator, @unchecked Sendable {
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetDeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsBuiltIn = @convention(c) (UnsafeRawPointer) -> Bool
    private typealias CreateFromDeviceID = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
    private typealias Open = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias Close = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias Actuate = @convention(c) (UnsafeRawPointer, Int32, UInt32, Float, Float) -> Int32

    static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    /// The lightest waveform the actuator is known to have.
    static let waveform: Int32 = 3
    static let sharpness: Float = 2

    private let createActuator: CreateFromDeviceID
    private let openActuator: Open
    private let closeActuator: Close
    private let actuate: Actuate
    private let deviceID: UInt64
    private var actuator: Unmanaged<AnyObject>?

    private init(createActuator: @escaping @convention(c) (UInt64) -> Unmanaged<AnyObject>?, openActuator: @escaping @convention(c) (UnsafeRawPointer) -> Int32,
                 closeActuator: @escaping @convention(c) (UnsafeRawPointer) -> Int32,
                 actuate: @escaping @convention(c) (UnsafeRawPointer, Int32, UInt32, Float, Float) -> Int32, deviceID: UInt64) {
        self.createActuator = createActuator
        self.openActuator = openActuator
        self.closeActuator = closeActuator
        self.actuate = actuate
        self.deviceID = deviceID
    }

    /// The capability check: every function resolves, a multitouch device exists, and its actuator opens.
    /// Nil otherwise, with nothing left behind.
    static func make() -> MultitouchActuator? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let createList = symbol("MTDeviceCreateList", as: CreateList.self),
              let getDeviceID = symbol("MTDeviceGetDeviceID", as: GetDeviceID.self),
              let create = symbol("MTActuatorCreateFromDeviceID", as: CreateFromDeviceID.self),
              let open = symbol("MTActuatorOpen", as: Open.self),
              let close = symbol("MTActuatorClose", as: Close.self),
              let actuate = symbol("MTActuatorActuate", as: Actuate.self),
              let devices = createList()?.takeRetainedValue() else { return nil }
        let isBuiltIn = symbol("MTDeviceIsBuiltIn", as: IsBuiltIn.self)
        var chosen: UInt64?
        for index in 0..<CFArrayGetCount(devices) {
            guard let device = CFArrayGetValueAtIndex(devices, index) else { continue }
            var id: UInt64 = 0
            guard getDeviceID(device, &id) == 0, id != 0 else { continue }
            // The trackpad under the hands, when there is one.
            if isBuiltIn?(device) == true { chosen = id; break }
            if chosen == nil { chosen = id }
        }
        guard let chosen else { return nil }
        let actuator = MultitouchActuator(createActuator: create, openActuator: open, closeActuator: close, actuate: actuate, deviceID: chosen)
        guard actuator.open() else { return nil }
        actuator.close()
        return actuator
    }

    func open() -> Bool {
        guard actuator == nil, let created = createActuator(deviceID) else { return actuator != nil }
        guard openActuator(created.toOpaque()) == 0 else {
            created.release()
            return false
        }
        actuator = created
        return true
    }

    func tick() -> Bool {
        guard let actuator else { return false }
        return actuate(actuator.toOpaque(), Self.waveform, 0, 0, Self.sharpness) == 0
    }

    func close() {
        guard let actuator else { return }
        _ = closeActuator(actuator.toOpaque())
        actuator.release()
        self.actuator = nil
    }
}

/// A tick on the trackpad for each key press. `fire` runs on the event tap's thread and only raises
/// a flag; a thread of its own talks to the actuator, so a slow trackpad can never hold a key back. Presses
/// that arrive while a tick is under way fold into one. Everything fails silently: a tick that cannot
/// play is simply not there, and after a run of failures the thread stops trying until the next launch.
final class TrackpadTick: @unchecked Sendable {
    /// The actuator is let go after this long without a key, and opened again on the next one.
    static let idleClose: TimeInterval = 30
    static let failureLimit = 5

    private let actuator: any TickActuator
    private let idleClose: TimeInterval
    private let wake = DispatchSemaphore(value: 0)
    private let pending = Atomic<Bool>(false)
    private let given = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    private let ticks = Atomic<Int>(0)
    private let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "tick")

    init(actuator: any TickActuator, idleClose: TimeInterval = TrackpadTick.idleClose) {
        self.actuator = actuator
        self.idleClose = idleClose
    }

    var count: Int { ticks.load(ordering: .relaxed) }
    /// True once the failures have used up the limit.
    var hasGivenUp: Bool { given.load(ordering: .relaxed) }

    /// Starts the thread. Safe to call again.
    func start() {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        let thread = Thread { [self] in run() }
        thread.name = "info.gabrimatic.switchtone.tick"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// One tick. No lock and no allocation: the event tap's thread calls it for every press.
    func fire() {
        guard !pending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        wake.signal()
    }

    private func run() {
        var failures = 0
        var isOpen = false
        while true {
            if isOpen {
                if wake.wait(timeout: .now() + idleClose) == .timedOut {
                    actuator.close()
                    isOpen = false
                    continue
                }
            } else {
                wake.wait()
            }
            pending.store(false, ordering: .releasing)
            guard failures < Self.failureLimit else { continue }
            if !isOpen { isOpen = actuator.open() }
            if isOpen, actuator.tick() {
                failures = 0
                ticks.add(1, ordering: .relaxed)
                continue
            }
            // After a sleep or a driver restart the old handle is dead: start over on the next press.
            if isOpen { actuator.close() }
            isOpen = false
            failures += 1
            if failures == Self.failureLimit {
                given.store(true, ordering: .relaxed)
                log.notice("trackpad tick stopped after \(Self.failureLimit) failures in a row")
            }
        }
    }
}

/// Hands the tick to the tap thread once the capability check has found one. Until then, and on a Mac
/// without an actuator, `fire` is one atomic load.
final class TickHolder: Sendable {
    private let bits = Atomic<UInt>(0)

    /// Called once. The tick lives as long as the app.
    func install(_ tick: TrackpadTick) {
        tick.start()
        bits.store(UInt(bitPattern: Unmanaged.passRetained(tick).toOpaque()), ordering: .releasing)
    }

    private var tick: TrackpadTick? {
        guard let pointer = UnsafeRawPointer(bitPattern: bits.load(ordering: .acquiring)) else { return nil }
        return Unmanaged<TrackpadTick>.fromOpaque(pointer).takeUnretainedValue()
    }

    func fire() { tick?.fire() }
    var count: Int { tick?.count ?? 0 }
}
