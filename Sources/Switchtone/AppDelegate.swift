import Darwin
import AppKit
import SwiftUI

/// The menu bar item and its panel, and the app's windows. Click opens the panel; Option-click
/// switches the sounds on or off without opening it. Opening the app again shows its Settings window,
/// so everything stays reachable when the menu bar symbol is hidden.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private lazy var windows = WindowCoordinator(controller: controller)
    /// Stands in for the symbol when it is not on screen (see `openPanel`).
    private var anchorWindow: NSWindow?
    /// The app that was in front when the panel opened; it gets the keyboard back on close.
    private var previousApp: NSRunningApplication?
    /// A plain `kill` (SIGTERM) skips `applicationWillTerminate`; this turns it into a normal quit,
    /// so the Control Center switch is told Switchtone is gone.
    private var terminationSignal: DispatchSourceSignal?
    private var diagnosticsSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch leaves freed heap behind; hand it back once everything has settled.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            malloc_zone_pressure_relief(nil, 0)
        }
        AppController.shared = controller
        // The typeface every surface the app draws itself uses; without it the system font stands in.
        if !PlexFont.register(resources: Bundle.main.resourceURL) { Logger.app.error("IBM Plex Sans did not register; drawing with the system font") }

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        term.resume()
        terminationSignal = term

        // The panel's SwiftUI view is built on first open, not at launch.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        controller.onStateChange = { [weak self] in self?.updateIcon() }
        controller.onMenuBarIconChange = { [weak self] in self?.applyMenuBarIcon() }
        controller.launch()
        // Only after the settings are read: with "Show menu bar icon" off the item is never created, so
        // it never takes room in a crowded menu bar, not even for a moment.
        applyMenuBarIcon()

        controller.onShowSettings = { [weak self] in
            guard let self else { return }
            if self.popover.isShown { self.popover.performClose(nil) }
            self.windows.showSettings()
        }
        let menuActions = MainMenu.Actions(about: #selector(showAbout), settings: #selector(showSettings), help: #selector(showHelp), target: self)
        MainMenu.install(actions: menuActions)
        // A brand-new install opens the welcome window; every other launch stays in the background.
        if controller.model.onboardingPending { windows.showOnboarding() }

        // SIGUSR1 writes the key counters to the log (no timer, nothing runs until the signal comes).
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.controller.logDiagnostics() } }
        usr1.resume()
        diagnosticsSignal = usr1
    }

    /// Opening Switchtone again (Finder, `open`, Spotlight) shows its window: the welcome window
    /// until it is finished, then Settings. The menu bar symbol may be hidden by the person (System
    /// Settings > Menu Bar), so nothing may depend on it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if popover.isShown { popover.performClose(nil) }
        windows.showForReopen()
        return false
    }

    /// Shows or removes the menu bar item to match "Show menu bar icon". Without it the app works the
    /// same: opening it again shows Settings, which holds every control.
    private func applyMenuBarIcon() {
        if controller.model.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.behavior = .terminationOnRemoval
            if let button = item.button {
                button.target = self
                button.action = #selector(statusItemClicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.setAccessibilityLabel("Switchtone")
            }
            statusItem = item
            updateIcon()
            logMenuBarItem(after: 1)
        } else {
            if popover.isShown { popover.performClose(nil) }
            if let item = statusItem {
                // Removing it here is not the person dragging it out of the bar: the app keeps running.
                item.behavior = []
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            Logger.app.info("menu bar symbol: off in Settings, no status item")
        }
    }

    @objc private func showSettings() { windows.showSettings() }
    @objc private func showAbout() { windows.showAbout() }

    /// Help is the About page: what Switchtone does and how to use it.
    @objc private func showHelp() { windows.showSettings(tab: .about) }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.app.info("quitting: \(self.controller.diagnostics, privacy: .public)")
        // Not running: the Control Center switch must not keep claiming the sounds are on.
        controller.publishNotRunning()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.option), event.type == .leftMouseUp {
            controller.toggleEnabled()
            Haptics.perform(.generic)
            return
        }
        togglePanel(sender)
    }

    private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) } else { openPanel() }
    }

    /// Opens the panel under the menu bar symbol, or under the top right corner of the main
    /// screen when the symbol is not on screen.
    private func openPanel() {
        controller.panelWillOpen()
        if popover.contentViewController == nil {
            let hosting = NSHostingController(rootView: PanelView(model: controller.model))
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
        }
        // Switchtone becomes the active app while its panel is open, as a menu bar
        // extra does: the panel's window is then truly key, so its controls
        // draw active, Tab moves between them, Escape closes and Command-Q quits.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        if let button = statusItem?.button, symbolIsOnScreen(button) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
        } else if let anchor = fallbackAnchor() {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Whether the symbol sits in a menu bar. A status item the system has not placed keeps a
    /// window at the screen's bottom left corner; one that is hidden by a menu bar manager sits far
    /// off the sides. The strip counts one menu bar tall, and a little more above the screen for a
    /// bar that auto-hides.
    private func symbolIsOnScreen(_ button: NSStatusBarButton) -> Bool {
        guard let window = button.window, window.isVisible, window.frame.width > 1 else { return false }
        return NSScreen.screens.contains { screen in
            let strip = NSRect(x: screen.frame.minX, y: screen.frame.maxY - 60, width: screen.frame.width, height: 120)
            return strip.contains(NSPoint(x: window.frame.midX, y: window.frame.midY))
        }
    }

    /// A one-point view under the menu bar at the top right of the main screen (the side the symbol lives on).
    private func fallbackAnchor() -> NSView? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let frame = NSRect(x: screen.visibleFrame.maxX - 60, y: screen.visibleFrame.maxY - 1, width: 1, height: 1)
        let window = anchorWindow ?? {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .statusBar
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            anchorWindow = window
            return window
        }()
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window.contentView
    }

    func popoverDidClose(_ notification: Notification) {
        // The panel's SwiftUI tree goes with it; it is built again in a moment when it next opens.
        popover.contentViewController = nil
        // SwiftUI finishes tearing the tree down over the next moments.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
        statusItem?.button?.highlight(false)
        anchorWindow?.orderOut(nil)
        controller.panelDidClose()
        // Closed with Escape, the symbol or a choice: hand the keyboard back.
        // Closed by clicking another app: that app is already in front.
        if NSApp.isActive, let previous = previousApp, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        previousApp = nil
    }

    /// Writes where the symbol ended up, so a missing one can be told from a hidden one in the log.
    private func logMenuBarItem(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, let item = self.statusItem else { return }
            let frame = item.button?.window?.frame ?? .zero
            let onScreen = item.button.map(self.symbolIsOnScreen) ?? false
            Logger.app.info("menu bar symbol: visible=\(item.isVisible, privacy: .public) onScreen=\(onScreen, privacy: .public) x=\(Int(frame.minX), privacy: .public) y=\(Int(frame.minY), privacy: .public) width=\(Int(frame.width), privacy: .public)")
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let model = controller.model
        let attention = model.permission != .granted || model.engine.problem != nil || model.profileProblem != nil
        let state: StatusIcon.State = attention ? .attention : (model.audible ? .on : .off)
        button.image = StatusIcon.image(state)
        button.appearsDisabled = state == .off
        button.toolTip = switch state {
        case .attention: model.permission != .granted ? "Switchtone needs Input Monitoring" : "Switchtone can't play sound"
        case .on: "Switchtone is on. Option-click to turn it off."
        case .off:
            if model.focusMuted { "Switchtone is muted by your Focus" }
            else if model.enabled && model.volumeMuted { "Switchtone's volume is at zero" }
            else { "Switchtone is off. Option-click to turn it on." }
        }
    }
}

import os
extension Logger {
    static let app = Logger(subsystem: "info.gabrimatic.switchtone", category: "app")
}
