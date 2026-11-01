// The Control Center and menu bar control for Switchtone: a switch that shows whether
// the sounds are on. Its action, SwitchtoneSoundsSwitchIntent, is shared with the app
// and runs only in the app's own process, so switching the sounds never crosses
// an unauthenticated channel. The state comes from SharedState, which the app
// rewrites on every change and refreshes this control from.
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SwitchtoneControls: WidgetBundle {
    var body: some Widget {
        SoundsControl()
    }
}

struct SoundsValueProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool { SharedState.readEnabled() }
}

struct SoundsControl: ControlWidget {
    static let kind = SharedState.controlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: SoundsValueProvider()) { enabled in
            ControlWidgetToggle(isOn: enabled, action: SwitchtoneSoundsSwitchIntent()) {
                Label("Keyboard Sounds", systemImage: "keyboard")
            } valueLabel: { isOn in
                Label(isOn ? "On" : "Off", systemImage: "keyboard")
            }
        }
        .displayName("Switchtone")
        .description("Shows whether Switchtone's keyboard sounds are on, and turns them on or off.")
    }
}
