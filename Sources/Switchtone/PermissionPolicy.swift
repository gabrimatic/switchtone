import CoreGraphics
import Dispatch
import Foundation

/// The Input Monitoring grant, read where it cannot cost a frame.
enum InputAccess {
    /// `CGPreflightListenEventAccess()` is a plain C call that takes about 10 ms on every call
    /// (a round trip to the permission service), more than one 120 Hz frame. It runs on a
    /// background queue and the answer is awaited, so the main thread never waits for it.
    static func preflight() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CGPreflightListenEventAccess())
            }
        }
    }
}

/// How often to check for the Input Monitoring grant, which has no notification.
enum PermissionWatch {
    static let settingsBundleID = "com.apple.systempreferences"
    /// While System Settings is in front the user is likely flipping the switch.
    static let fastInterval: TimeInterval = 1
    /// Otherwise app switches trigger a check; this only catches a grant made some other way.
    static let slowInterval: TimeInterval = 20

    static func interval(frontmost bundleID: String?) -> TimeInterval {
        bundleID == settingsBundleID ? fastInterval : slowInterval
    }
}

/// Decides whether a running event tap is really hearing keys.
enum SilentTap {
    enum Verdict: Equatable {
        /// Nothing typed yet (or a password field hides the keys): keep watching.
        case wait
        /// A key reached the tap.
        case healthy
        /// Two minutes with no typing: stop watching.
        case gaveUp
        /// Keys were typed but none arrived: a fresh process usually fixes it.
        case relaunch
        /// Still deaf right after such a relaunch: the grant in the list is another copy's.
        case stale
    }

    static let watchSeconds: TimeInterval = 120
    /// Relaunch at most once in this window; within it, a deaf tap means a stale grant.
    static let relaunchWindow: TimeInterval = 600

    /// - Parameters:
    ///   - heard: the tap received a key event since the watch began.
    ///   - elapsed: seconds since the watch began.
    ///   - sinceLastKey: the system's seconds since the last key press anywhere.
    ///   - secureInput: secure keyboard entry is on, which hides keys from every tap.
    ///   - sinceRelaunch: seconds since Switchtone last relaunched itself for this, if ever.
    static func verdict(heard: Bool, elapsed: TimeInterval, sinceLastKey: TimeInterval, secureInput: Bool,
                        sinceRelaunch: TimeInterval?) -> Verdict {
        if heard { return .healthy }
        if elapsed > watchSeconds { return .gaveUp }
        // A key pressed after the watch began, at least a second ago.
        guard !secureInput, sinceLastKey < elapsed - 1 else { return .wait }
        if let sinceRelaunch, sinceRelaunch >= 0, sinceRelaunch < relaunchWindow { return .stale }
        return .relaunch
    }
}
