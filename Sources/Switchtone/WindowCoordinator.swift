import Darwin
import AppKit
import SwiftUI

/// Builds and shows Switchtone's windows (welcome, Settings, About). Switchtone stays a menu bar app with
/// no Dock icon; its menus show while one of its windows is in front.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private let controller: AppController
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var aboutWindow: NSWindow?
    /// Settings was hidden to make room for the welcome window and comes back when that closes.
    private var returnToSettings = false

    init(controller: AppController) {
        self.controller = controller
        super.init()
        controller.onShowOnboarding = { [weak self] in self?.showOnboarding() }
    }

    // MARK: Showing

    func showSettings(tab: SettingsTab? = nil) {
        returnToSettings = false
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        if let tab, let host = window.contentViewController as? SettingsHost { host.navigation.tab = tab }
        present(window)
    }

    func showOnboarding() {
        let window = onboardingWindow ?? Self.makeOnboardingWindow(model: controller.model) { [weak self] in
            self?.onboardingWindow?.close()
        }
        window.delegate = self
        onboardingWindow = window
        // One window at a time: Settings steps aside (a second frame behind the glass reads as a
        // doubled edge) and returns when the welcome window closes.
        if let settings = settingsWindow, settings.isVisible {
            settings.orderOut(nil)
            returnToSettings = true
        }
        present(window)
    }

    func showAbout() {
        let window = aboutWindow ?? Self.makeAboutWindow(model: controller.model)
        window.delegate = self
        aboutWindow = window
        present(window)
    }

    /// What opening Switchtone again shows: the welcome window until it is finished, then Settings.
    func showForReopen() {
        if controller.model.onboardingPending { showOnboarding() } else { showSettings() }
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible { window.center(); restorePosition(window) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Self.clearInitialFocus(window)
        controller.windowsChanged(anyOpen: true)
    }

    /// A window opens with nothing focused, as Apple's windows do. With Full Keyboard Access on, SwiftUI
    /// puts the focus ring on the first control as the window becomes key, and Space would then flip a
    /// setting nobody chose. Tab starts from the first control as usual. Done in a few short passes,
    /// because the focus lands a moment after the window shows, and only while the window is new.
    static func clearInitialFocus(_ window: NSWindow?) {
        for delay in [0.0, 0.12, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window, window.isVisible, window.firstResponder !== window else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    /// Settings remembers where it was and which page it showed.
    private func restorePosition(_ window: NSWindow) {
        guard window === settingsWindow, let saved = UserDefaults.standard.string(forKey: Self.positionKey) else { return }
        let point = NSPointFromString(saved)
        // Ignore a position from a display that is no longer there.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) }) else { return }
        window.setFrameTopLeftPoint(point)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: window.frame.minX, y: window.frame.maxY)), forKey: Self.positionKey)
    }

    // MARK: Closing

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        // Done, Esc and the close button all end the welcome the same way.
        if closing === onboardingWindow { controller.completeOnboarding() }
        // The closing window still counts as visible during this call: look again on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if closing === onboardingWindow, returnToSettings { showSettings() } else { windowsClosed() }
        }
    }

    private func windowsClosed() {
        let open = [settingsWindow, onboardingWindow, aboutWindow].contains { $0?.isVisible == true }
        guard !open else { return }
        controller.windowsChanged(anyOpen: false)
        // Let the closed windows go, so their SwiftUI trees hold no memory while Switchtone runs.
        for window in [settingsWindow, onboardingWindow, aboutWindow] { window?.delegate = nil; window?.contentViewController = nil }
        settingsWindow = nil
        onboardingWindow = nil
        aboutWindow = nil
        // SwiftUI finishes tearing the trees down over the next moments.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    // MARK: Factories

    static let positionKey = "settingsWindowTopLeft"
    static let tabKey = "settingsTab"

    private func makeSettingsWindow() -> NSWindow {
        let window = Self.makeSettingsWindow(model: controller.model)
        window.delegate = self
        return window
    }

    static func makeSettingsWindow(model: AppModel) -> NSWindow {
        let host = SettingsHost(model: model)
        let window = NSWindow(contentViewController: host)
        window.title = host.navigation.tab.title
        host.navigation.onChange = { [weak window] tab in
            window?.title = tab.title
            clearInitialFocus(window)
        }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "SwitchtoneSettings")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.backgroundColor = Palette.groundNS
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 500)
        window.setContentSize(NSSize(width: 720, height: 540))
        return window
    }

    static func makeOnboardingWindow(model: AppModel, done: @escaping () -> Void) -> NSWindow {
        let root = StyledRoot {
            OnboardingView(model: model, icon: NSApp.applicationIconImage, done: done)
        }
        return flatWindow(root, title: "Welcome to Switchtone", resizable: false)
    }

    static func makeAboutWindow(model: AppModel) -> NSWindow {
        let root = StyledRoot {
            AboutView(icon: NSApp.applicationIconImage, version: model.version, build: model.build)
        }
        return flatWindow(root, title: "About Switchtone", resizable: false)
    }

    /// A titled window on the flat ink or paper ground, with a transparent title bar and the content
    /// running under it. Glass is for controls; the window itself is quiet.
    private static func flatWindow<Root: View>(_ root: Root, title: String, resizable: Bool) -> NSWindow {
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = .preferredContentSize
        let size = hosting.view.fittingSize
        var mask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = EscapableWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.groundNS
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }
}

/// A titled window that Esc closes, like a sheet.
final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Which page Settings shows. Remembered between openings.
@MainActor @Observable
final class SettingsNavigation {
    var tab: SettingsTab {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: WindowCoordinator.tabKey)
            onChange?(tab)
        }
    }
    @ObservationIgnored var onChange: ((SettingsTab) -> Void)?

    init() {
        tab = UserDefaults.standard.string(forKey: WindowCoordinator.tabKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}

/// The Settings window's content, and the page it shows.
@MainActor
final class SettingsHost: NSHostingController<StyledRoot<SettingsRoot>> {
    let navigation: SettingsNavigation

    init(model: AppModel) {
        let navigation = SettingsNavigation()
        self.navigation = navigation
        super.init(rootView: StyledRoot { SettingsRoot(model: model, navigation: navigation) })
        sizingOptions = []
    }

    @available(*, unavailable)
    required dynamic init?(coder: NSCoder) { fatalError("not used") }
}
