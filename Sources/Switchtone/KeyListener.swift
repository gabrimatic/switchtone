import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Synchronization
import os

/// A listen-only CGEventTap on its own thread with its own run loop, so the
/// panel, the main thread or anything else never delays a sound.
///
/// The tap needs the Input Monitoring permission. Without it macOS may still
/// create the tap but deliver no key events, so the owner checks
/// `CGPreflightListenEventAccess()` before `start()` and retries until both
/// succeed; a grant in System Settings takes effect without a relaunch.
///
/// Everything the callback touches is either owned by the tap thread or an
/// atomic: no lock can make a keystroke wait.
final class KeyListener: @unchecked Sendable {
    struct Counters: Sendable {
        var received = 0
        var played = 0
        var skippedDisabled = 0
        var skippedSecure = 0
        var skippedRepeat = 0
        var skippedOrphanRelease = 0
        /// Event timestamp to callback, microseconds: the middle value, the 95th percentile and the
        /// worst one. The middle value is the one that says how Switchtone performs; one slow press (a busy
        /// Mac, a core waking from sleep) moves the average and the maximum but not the median.
        var tapDelayMedian = 0
        var tapDelayP95 = 0
        var tapDelayAverage = 0
        var tapDelayMax = 0
        /// The first key after at least `quietSeconds` without one, which also wakes the tap thread
        /// from idle: its average delay and how many there were.
        var tapDelayAfterQuiet = 0
        var afterQuietCount = 0
    }

    /// A pause this long before a key makes it the "first key after quiet".
    static let quietSeconds = 5.0
    /// Delay histogram: 250 µs buckets up to 10 ms, then one for everything slower.
    static let delayBucketWidth = 250
    static let delayBuckets = 41

    private final class Bucket: Sendable { let count = Atomic<Int>(0) }

    struct Gate: Sendable {
        var enabled: Bool
        var muteSecure: Bool
    }

    /// Control-Option-Command-K. Not bound by macOS or common apps.
    static let shortcutKeyCode: Int64 = 40
    static let shortcutFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    static let shortcutSymbols = ["⌃", "⌥", "⌘", "K"]
    static let shortcutDisplay = shortcutSymbols.joined()
    static let shortcutSpoken = "Control Option Command K"

    /// Exactly Control-Option-Command-K; with Shift added it is someone else's shortcut.
    static func isShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        return keyCode == shortcutKeyCode && flags.intersection(relevant) == shortcutFlags
    }

    /// What the tap hears: key presses, releases and modifier changes, plus a left click. The click
    /// is counted only as "a click happened" (to start the output ahead of the next key); its
    /// position and target are never read. Scrolls and every other event are not heard.
    static let eventMask: CGEventMask = CGEventMask(
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue))

    private let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "keys")
    private let onStrike: @Sendable (Strike) -> Void
    private let onShortcut: @Sendable () -> Void
    /// Called (off the tap thread's key path) when macOS switched the tap off
    /// because the permission was revoked.
    private let onRevoked: @Sendable () -> Void
    private let onActivity: @Sendable () -> Void
    private let gate: @Sendable () -> Gate

    /// The tap port, readable from the tap thread (to re-enable it) and the main
    /// thread (start and stop). Only the rare disable events and start/stop touch it.
    private struct PortBox: @unchecked Sendable { var port: CFMachPort? }
    private let portBox = Mutex(PortBox())
    private var tap: CFMachPort? {
        get { portBox.withLock { $0.port } }
        set { portBox.withLock { $0.port = newValue } }
    }

    // Main thread only.
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    // Tap thread only.
    private var lastFlags: UInt64 = 0
    private var dynamics = TypingDynamics()
    /// Host time of each key's press, by key code (0: not down). A fixed table,
    /// so the key path never allocates.
    private static let slotCount = 256
    private var pressedAt = [UInt64](repeating: 0, count: KeyListener.slotCount)
    private var rng = SplitMix64(seed: 0x6B65_7973)
    private var delaySum: UInt64 = 0
    private var delayCount: UInt64 = 0
    private var quietSum: UInt64 = 0
    private var quietCount: UInt64 = 0
    /// Host time of the previous key event, for the quiet-gap rule.
    private var lastEventHost: UInt64 = 0

    // Read from anywhere.
    private let received = Atomic<Int>(0)
    private let played = Atomic<Int>(0)
    private let skippedDisabled = Atomic<Int>(0)
    private let skippedSecure = Atomic<Int>(0)
    private let skippedRepeat = Atomic<Int>(0)
    private let skippedOrphan = Atomic<Int>(0)
    private let delayAverage = Atomic<Int>(0)
    private let delayMax = Atomic<Int>(0)
    private let quietAverage = Atomic<Int>(0)
    private let quietSamples = Atomic<Int>(0)
    private let delayHistogram: [Bucket] = (0..<KeyListener.delayBuckets).map { _ in Bucket() }

    init(gate: @escaping @Sendable () -> Gate, onStrike: @escaping @Sendable (Strike) -> Void,
         onShortcut: @escaping @Sendable () -> Void, onActivity: @escaping @Sendable () -> Void = {},
         onRevoked: @escaping @Sendable () -> Void = {}) {
        self.onActivity = onActivity
        self.onRevoked = onRevoked
        self.gate = gate
        self.onStrike = onStrike
        self.onShortcut = onShortcut
    }

    var isRunning: Bool { tap != nil }

    var counters: Counters {
        let (median, p95) = delayPercentiles()
        return Counters(received: received.load(ordering: .relaxed), played: played.load(ordering: .relaxed),
                        skippedDisabled: skippedDisabled.load(ordering: .relaxed), skippedSecure: skippedSecure.load(ordering: .relaxed),
                        skippedRepeat: skippedRepeat.load(ordering: .relaxed), skippedOrphanRelease: skippedOrphan.load(ordering: .relaxed),
                        tapDelayMedian: median, tapDelayP95: p95,
                        tapDelayAverage: delayAverage.load(ordering: .relaxed), tapDelayMax: delayMax.load(ordering: .relaxed),
                        tapDelayAfterQuiet: quietAverage.load(ordering: .relaxed), afterQuietCount: quietSamples.load(ordering: .relaxed))
    }

    /// The middle and the 95th-percentile delay in microseconds, from the histogram (each bucket
    /// reports its midpoint; the overflow bucket reports its lower edge).
    private func delayPercentiles() -> (median: Int, p95: Int) {
        let counts = delayHistogram.map { $0.count.load(ordering: .relaxed) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return (0, 0) }
        func value(atRank rank: Int) -> Int {
            var seen = 0
            for (i, n) in counts.enumerated() {
                seen += n
                if seen >= rank {
                    return i == Self.delayBuckets - 1 ? i * Self.delayBucketWidth : i * Self.delayBucketWidth + Self.delayBucketWidth / 2
                }
            }
            return 0
        }
        return (value(atRank: (total + 1) / 2), value(atRank: max(1, (total * 95 + 99) / 100)))
    }

    /// Creates the tap. Returns false when macOS refuses it. Main thread.
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                Unmanaged<KeyListener>.fromOpaque(info).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        tap = port
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let box = port
        let thread = Thread { [weak self] in
            guard let self, let source = CFMachPortCreateRunLoopSource(nil, box, 0) else { ready.signal(); return }
            self.lastFlags = flags
            for i in 0..<self.pressedAt.count { self.pressedAt[i] = 0 }
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: box, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "info.gabrimatic.switchtone.tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        log.info("event tap running")
        return true
    }

    /// Main thread.
    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        log.info("event tap stopped")
    }

    /// True while the tap exists and macOS still lets it run. Revoking Input
    /// Monitoring disables it.
    var isHealthy: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: Tap thread

    /// Takes synthetic events too (created, never posted).
    func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log.info("event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
            // Revoking Input Monitoring switches the tap off with "user input";
            // let the owner check whether it stayed off, so the menu bar symbol follows at once.
            if type == .tapDisabledByUserInput { onRevoked() }
            return
        case .keyDown, .keyUp, .flagsChanged:
            break
        case .leftMouseDown:
            onActivity()
            return
        default:
            return
        }
        let host = HostClock.now
        let afterQuiet = lastEventHost == 0 || HostClock.seconds(ticks: host &- lastEventHost) >= Self.quietSeconds
        lastEventHost = host
        measure(event.timestamp, afterQuiet: afterQuiet)

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var down = type == .keyDown
        if type == .flagsChanged {
            let flags = event.flags.rawValue
            defer { lastFlags = flags }
            guard let bit = ModifierBits.mask(forKeyCode: keyCode) else { return }
            // Caps lock reports its lock state, not the key position: every
            // change is a physical press, so play the press.
            down = keyCode == 57 ? true : (flags & bit) != 0
        }
        received.add(1, ordering: .relaxed)

        if type == .keyDown || type == .keyUp, Self.isShortcut(keyCode: keyCode, flags: event.flags) {
            if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onShortcut() }
            pressedAt[Self.slot(keyCode)] = 0
            return
        }

        // Holding a key repeats keyDown; a real switch only bottoms out once.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            skippedRepeat.add(1, ordering: .relaxed)
            return
        }

        let state = gate()
        guard state.enabled else {
            pressedAt[Self.slot(keyCode)] = 0
            skippedDisabled.add(1, ordering: .relaxed)
            return
        }
        // macOS already withholds key events from taps while a password field
        // has focus, but modifier changes still arrive; this keeps them silent too.
        if state.muteSecure, IsSecureEventInputEnabled() {
            pressedAt[Self.slot(keyCode)] = 0
            skippedSecure.add(1, ordering: .relaxed)
            return
        }

        var strike = Strike(keyClass: KeyClass(keyCode: keyCode), down: down, keyCode: keyCode)
        if down {
            strike.intensity = dynamics.press(at: host)
            pressedAt[Self.slot(keyCode)] = host
        } else if keyCode != 57 {
            // A release with no press heard (held before Switchtone started, or
            // pressed while muted) would be a stray click.
            let slot = Self.slot(keyCode)
            let pressed = pressedAt[slot]
            pressedAt[slot] = 0
            guard pressed != 0 else {
                skippedOrphan.add(1, ordering: .relaxed)
                return
            }
            strike.intensity = dynamics.intensity
            strike.delay = ReleaseTiming.delay(sincePress: HostClock.seconds(ticks: host &- pressed),
                                               spring: rng.float(in: ReleaseTiming.springReturn))
        }
        played.add(1, ordering: .relaxed)
        onStrike(strike)
    }

    private static func slot(_ keyCode: Int64) -> Int { Int(truncatingIfNeeded: keyCode) & (slotCount - 1) }

    /// Event timestamp (nanoseconds since boot) to now: histogram, running average and maximum, and
    /// the same average for the first key after a quiet spell.
    func measure(_ timestamp: CGEventTimestamp, afterQuiet: Bool = false, now: UInt64 = HostClock.uptimeNanos) {
        guard timestamp > 0, now >= timestamp else { return }
        let micros = (now - timestamp) / 1_000
        guard micros < 1_000_000 else { return }   // clock mismatch or a stalled tap; not a latency sample
        delaySum &+= micros
        delayCount &+= 1
        delayAverage.store(Int(delaySum / delayCount), ordering: .relaxed)
        if Int(micros) > delayMax.load(ordering: .relaxed) { delayMax.store(Int(micros), ordering: .relaxed) }
        delayHistogram[min(Self.delayBuckets - 1, Int(micros) / Self.delayBucketWidth)].count.add(1, ordering: .relaxed)
        if afterQuiet {
            quietSum &+= micros
            quietCount &+= 1
            quietAverage.store(Int(quietSum / quietCount), ordering: .relaxed)
            quietSamples.store(Int(quietCount), ordering: .relaxed)
        }
    }
}
