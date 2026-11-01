import Foundation
import Observation

/// What the panel and the windows show, as plain state.
@MainActor
@Observable
final class AppModel {
    enum Permission: Equatable {
        /// The tap runs and keys arrive.
        case granted
        /// Switchtone is not allowed yet.
        case missing
        /// Allowed in Settings, but the switch belongs to another copy of Switchtone.
        case stale
    }

    enum Login: Equatable {
        case on, off, needsApproval
        /// macOS refused the change; the details go to the log, not the panel.
        case failed
    }

    var enabled = true
    var profile: Profile = .tactile
    var volume: Float = 0.6
    var spatial = true
    var headTracking = true
    var muteSecure = true
    var focusMuted = false
    /// The menu bar icon is shown. With it off everything stays reachable from Settings.
    var showMenuBarIcon = true
    /// A trackpad tick with each key press.
    var trackpadTick = true
    /// This Mac has a trackpad actuator Switchtone can use.
    var tickAvailable = true
    var permission: Permission = .granted
    /// The user asked for the permission and Switchtone is watching for the switch.
    var waitingForGrant = false
    /// Switchtone asked for the permission on an earlier launch, so the list may
    /// already show it switched on for another copy.
    var returningInstall = false
    /// Switchtone has already used the system prompt for Input Monitoring (macOS shows it once).
    var accessRequested = false
    /// The welcome window has not been finished yet.
    var onboardingPending = false
    /// Shown for a moment after the permission arrives.
    var justGranted = false
    var login: Login = .on
    var engine = EngineStatus()
    var profileProblem: String?
    /// The profile whose card is playing its preview.
    var previewing: Profile?

    @ObservationIgnored weak var controller: AppController?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var build: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }

    /// Below this the volume is silence: strikes are skipped and the output stays asleep.
    nonisolated static let silentVolume: Float = 0.001

    var volumeMuted: Bool { volume <= Self.silentVolume }

    /// Sounds actually play: switched on, allowed, not muted by a Focus, and loud enough to hear.
    var audible: Bool { enabled && !focusMuted && permission == .granted && !volumeMuted }

    /// Audible and nothing in the way: what the header badge shows.
    var playing: Bool { audible && engine.problem == nil && profileProblem == nil }

    /// The state in a word or two: Off (switched off), Not listening (no permission), Paused (a Focus),
    /// No sound (nothing to play on), Muted (volume 0). The reason and what to do about it live in
    /// the notice below the header, never in both places.
    var statusLine: String {
        if permission != .granted { return "Not listening" }
        if !enabled { return "Off" }
        // The same words as the notice under the header, so the two never name one state twice.
        if focusMuted { return "Paused" }
        if engine.problem != nil || profileProblem != nil { return "No sound" }
        if volumeMuted { return "Muted" }
        return "On · \(profile.title)"
    }

    var routeLine: String {
        let route = engine.route
        guard spatial else { return "Off · plain stereo" }
        switch route.kind {
        // With no output the notice above already says so; this row keeps to its own subject.
        case .none: return "Spatial"
        // The Follow Head Movement row below states whether tracking is on, so this
        // line is only the route. Around the separator, no-break spaces keep a
        // wrapped line from ending or starting on a lone dot.
        case .headphones: return route.name
        case .builtInSpeakers, .externalSpeakers: return "\(route.name)\u{00A0}·\u{00A0}Spatial"
        }
    }

    var routeSymbol: String {
        switch engine.route.kind {
        case .headphones:
            let name = engine.route.name.lowercased()
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            return "headphones"
        case .builtInSpeakers: return "laptopcomputer"
        case .externalSpeakers: return "hifispeaker"
        case .none: return "speaker.wave.2"
        }
    }

    /// The one thing in the way, most fundamental first. The panel shows only
    /// this notice, so two cards never explain the same silence.
    enum Blocker: Equatable {
        case permission(Permission)
        case noSound(String)
        case focus
    }

    var blocker: Blocker? {
        if permission != .granted { return .permission(permission) }
        if let problem = engine.problem ?? profileProblem { return .noSound(problem) }
        if focusMuted { return .focus }
        return nil
    }

    var volumeSymbol: String { volumeMuted ? "speaker.slash" : "speaker.wave.3" }
}
