import AppIntents

/// Turns Switchtone's sounds on when they are off, and off when they are on.
/// Compiled into both the app and the Control Center extension, so the control
/// can name it, but it runs only inside the Switchtone app: the extension has no way
/// to change Switchtone, and no other process can send Switchtone a toggle.
struct ToggleSwitchtoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Switchtone Sounds"
    static let description = IntentDescription("Turns the keyboard sounds off when they are on, and on when they are off.")

    /// Run in the main app only, never in an extension.
    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        #if SWITCHTONE_APP
        guard let controller = AppController.shared else { return .result(dialog: "Open Switchtone first.") }
        controller.toggleEnabled()
        return .result(dialog: controller.model.enabled ? "Switchtone is on." : "Switchtone is off.")
        #else
        // Unreachable: the system runs this intent in the app. If it ever lands here, change nothing.
        return .result(dialog: "Open Switchtone to turn its sounds on or off.")
        #endif
    }
}

/// What the Control Center switch runs: set the sounds on or off. Like
/// ToggleSwitchtoneIntent it runs only inside the Switchtone app. Not offered in Shortcuts.
struct SwitchtoneSoundsSwitchIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Keyboard Sounds"
    static let isDiscoverable = false

    @Parameter(title: "On")
    var value: Bool

    @available(macOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if SWITCHTONE_APP
        AppController.shared?.setEnabled(value)
        #endif
        return .result()
    }
}
