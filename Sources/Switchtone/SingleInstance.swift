import AppKit
import Synchronization

/// One Switchtone at a time. Opening the app again (Finder, Spotlight, `open`) never starts a second
/// process: macOS hands the running one a reopen request. A second process only exists when the
/// binary is started directly, or when Switchtone relaunches itself; this covers both.
enum SingleInstance {
    /// Passed by Switchtone when it relaunches itself: the new process waits for the old one to finish quitting.
    static let relaunchArgument = "--relaunched"
    /// How long a relaunched process waits for the old one before it carries on.
    static let handoverSeconds: TimeInterval = 5

    /// Another running Switchtone, if there is one.
    static func other(bundleIdentifier: String? = Bundle.main.bundleIdentifier, processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
                      running: (String) -> [NSRunningApplication] = { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }) -> NSRunningApplication? {
        guard let bundleIdentifier else { return nil }
        return running(bundleIdentifier).first { $0.processIdentifier != processIdentifier && !$0.isTerminated }
    }

    /// Called first thing at launch. Returns false when this process must exit because Switchtone already runs:
    /// the running one is asked to show its window (the same request Finder sends).
    @MainActor
    static func claim(arguments: [String] = CommandLine.arguments) -> Bool {
        guard var existing = other() else { return true }
        if arguments.contains(relaunchArgument) {
            // We replace it: wait for the old process to go.
            let deadline = Date().addingTimeInterval(handoverSeconds)
            while Date() < deadline, !existing.isTerminated {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                guard let next = other() else { return true }
                existing = next
            }
            return other() == nil
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sent = Flag()
        NSWorkspace.shared.openApplication(at: existing.bundleURL ?? Bundle.main.bundleURL, configuration: configuration) { _, _ in
            sent.value.store(true, ordering: .releasing)
        }
        // The request is delivered from the main run loop's side; keep it turning until it is sent.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !sent.value.load(ordering: .acquiring) { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        return false
    }
}

private final class Flag: Sendable { let value = Atomic<Bool>(false) }
