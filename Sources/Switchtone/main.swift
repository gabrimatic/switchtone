import AppKit

MainActor.assumeIsolated {
    // A second Switchtone hands over to the running one and leaves.
    guard SingleInstance.claim() else { exit(0) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
