import AppIntents

/// The switch profiles, for Shortcuts and Siri.
enum ProfileOption: String, AppEnum {
    case linear, tactile, clicky

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Switch Profile"
    static let caseDisplayRepresentations: [ProfileOption: DisplayRepresentation] = [
        .linear: DisplayRepresentation(title: "Linear", subtitle: "Creamy"),
        .tactile: DisplayRepresentation(title: "Tactile", subtitle: "Thocky"),
        .clicky: DisplayRepresentation(title: "Clicky", subtitle: "Crisp"),
    ]

    var profile: Profile { Profile(rawValue: rawValue) ?? .tactile }
}

/// Turns the sounds on or off. Hidden from the Shortcuts library: Turn Switchtone Sounds On and
/// Off do the same and read better there.
struct SetSwitchtoneSoundsIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Switchtone Sounds"
    static let description = IntentDescription("Turns Switchtone's keyboard sounds on or off.")
    static let isDiscoverable = false

    @Parameter(title: "On", default: true)
    var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn Switchtone sounds \(\.$on)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        controller.setEnabled(on)
        return .result(dialog: on ? "Switchtone is on." : "Switchtone is off.")
    }
}

/// Mutes Switchtone: the sounds go off, whatever they were. Its own intent, so "Mute Switchtone"
/// never turns the sounds on.
struct MuteSwitchtoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Switchtone Sounds Off"
    static let description = IntentDescription("Turns Switchtone's keyboard sounds off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        controller.setEnabled(false)
        return .result(dialog: "Switchtone is off.")
    }
}

/// Unmutes Switchtone: the sounds go on, whatever they were.
struct UnmuteSwitchtoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Switchtone Sounds On"
    static let description = IntentDescription("Turns Switchtone's keyboard sounds on.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        controller.setEnabled(true)
        return .result(dialog: "Switchtone is on.")
    }
}

/// Picks the switch profile.
struct SetSwitchtoneProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Switchtone Switches"
    static let description = IntentDescription("Chooses linear, tactile or clicky switch sounds.")

    @Parameter(title: "Switches")
    var profile: ProfileOption

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$profile) switches in Switchtone")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        controller.choose(profile.profile)
        return .result(dialog: "Switchtone plays \(profile.profile.title.lowercased()) switches.")
    }
}

/// Sets the volume, 0 to 100.
struct SetSwitchtoneVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Switchtone Volume"
    static let description = IntentDescription("Sets how loud the keyboard sounds are.")

    @Parameter(title: "Volume", description: "0 to 100", inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set Switchtone volume to \(\.$percent)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        let clamped = min(100, max(0, percent))
        controller.setVolume(Float(clamped) / 100, final: false)
        return .result(dialog: "Switchtone volume is \(clamped)%.")
    }
}

/// Mutes Switchtone while a chosen Focus is on, from System Settings > Focus > Focus Filters.
struct SwitchtoneFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Switchtone"
    static let description: IntentDescription? = IntentDescription("Mute the keyboard sounds while this Focus is on.")

    /// Nil when the Focus turns off, which unmutes Switchtone.
    @Parameter(title: "Mute Switchtone")
    var mute: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: mute == true ? "Mute Switchtone" : "Keep Switchtone playing")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppController.shared?.setFocusMuted(mute ?? false)
        return .result()
    }
}

struct SwitchtoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleSwitchtoneIntent(), phrases: ["Toggle \(.applicationName)"],
                    shortTitle: "Toggle Sounds", systemImageName: "keyboard")
        AppShortcut(intent: MuteSwitchtoneIntent(), phrases: ["Mute \(.applicationName)", "Turn \(.applicationName) off"],
                    shortTitle: "Sounds Off", systemImageName: "keyboard")
        AppShortcut(intent: UnmuteSwitchtoneIntent(), phrases: ["Unmute \(.applicationName)", "Turn \(.applicationName) on"],
                    shortTitle: "Sounds On", systemImageName: "keyboard")
        AppShortcut(intent: SetSwitchtoneProfileIntent(), phrases: ["Change \(.applicationName) switches", "Use \(\.$profile) switches in \(.applicationName)"],
                    shortTitle: "Set Switches", systemImageName: "switch.2")
        AppShortcut(intent: SetSwitchtoneVolumeIntent(), phrases: ["Set \(.applicationName) volume"],
                    shortTitle: "Set Volume", systemImageName: "speaker.wave.2")
    }
}
