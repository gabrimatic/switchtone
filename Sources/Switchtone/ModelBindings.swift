import SwiftUI

/// Bindings for the switches and the slider.
///
/// A `Binding(get:set:)` written inside a view body inherits the view's main-actor isolation, and
/// SwiftUI may evaluate a binding's getter off the main thread. The runtime then traps on the
/// isolation check. These bindings never touch main-actor state from a closure: the getter
/// returns a value captured when the view body ran, and the setter hops to the main actor itself.
extension Binding {
    /// A binding whose getter returns `value` (read in the view body) and whose setter applies the
    /// change on the main actor. Both closures are `@Sendable`, so neither inherits isolation.
    nonisolated static func snapshot(_ value: Value, apply: @escaping @MainActor @Sendable (Value) -> Void) -> Binding<Value>
    where Value: Sendable {
        Binding(get: { @Sendable in value }, set: { @Sendable newValue in Task { @MainActor in apply(newValue) } })
    }
}

extension AppModel {
    var enabledBinding: Binding<Bool> {
        .snapshot(enabled) { [weak self] in self?.controller?.setEnabled($0) }
    }

    var spatialBinding: Binding<Bool> {
        .snapshot(spatial) { [weak self] in self?.controller?.setSpatial($0) }
    }

    var headTrackingBinding: Binding<Bool> {
        .snapshot(headTracking) { [weak self] in self?.controller?.setHeadTracking($0) }
    }

    var muteSecureBinding: Binding<Bool> {
        .snapshot(muteSecure) { [weak self] in self?.controller?.setMuteSecure($0) }
    }

    var showMenuBarIconBinding: Binding<Bool> {
        .snapshot(showMenuBarIcon) { [weak self] in self?.controller?.setShowMenuBarIcon($0) }
    }

    var trackpadTickBinding: Binding<Bool> {
        .snapshot(trackpadTick) { [weak self] in self?.controller?.setTrackpadTick($0) }
    }

    var loginBinding: Binding<Bool> {
        .snapshot(login == .on) { [weak self] in self?.controller?.setLogin($0) }
    }

    var volumeBinding: Binding<Double> {
        .snapshot(Double(volume)) { [weak self] in self?.controller?.setVolume(Float($0), final: false) }
    }

    /// The slider reports that the drag ended: play the new level once. Reads the model on the main actor.
    nonisolated func volumeEditingChanged(_ editing: Bool) {
        guard !editing else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            controller?.setVolume(volume, final: true)
        }
    }
}
