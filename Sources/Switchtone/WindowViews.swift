import SwiftUI

// The windows: welcome, Settings (General, Sounds, Permissions, About) and the About window. They share the
// panel's pieces (cards, rows, the palette and the type) so the app reads as one thing.

/// The three accessibility settings every window view honours.
private struct WindowAccessibility: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(\.windowStyle, WindowStyle(plainSurfaces: reduceTransparency,
                                                       highContrast: contrast == .increased,
                                                       stillMotion: reduceMotion))
    }
}

/// What the window views draw with, resolved once from the system settings.
struct WindowStyle: Equatable {
    var plainSurfaces = false
    var highContrast = false
    var stillMotion = false

    var spring: Animation { stillMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3) }
    @MainActor var change: AnyTransition { stillMotion ? .opacity : AnyTransition(.blurReplace) }
}

private struct WindowStyleKey: EnvironmentKey { static let defaultValue = WindowStyle() }

extension EnvironmentValues {
    var windowStyle: WindowStyle {
        get { self[WindowStyleKey.self] }
        set { self[WindowStyleKey.self] = newValue }
    }
}

extension View {
    /// Resolves the three accessibility settings into `\.windowStyle`.
    func windowAccessibility() -> some View {
        modifier(WindowAccessibility())
    }
}

/// Wraps a window's root view so every view inside reads the resolved settings.
struct StyledRoot<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().windowAccessibility()
    }
}

// MARK: - Permission row

/// The Input Monitoring permission: what it is for, a live status in words, and one button. "Allow…" asks
/// through the system prompt; once that prompt is used up (denied or dismissed) the button opens the exact
/// Settings pane instead.
struct PermissionRow: View {
    @Bindable var model: AppModel
    @Environment(\.windowStyle) private var style

    private var state: State {
        switch model.permission {
        case .granted: .allowed
        case .stale: .stale
        case .missing: model.accessRequested ? .denied : .askable
        }
    }

    private enum State { case allowed, askable, denied, stale }

    private var detail: String {
        switch state {
        case .stale: "macOS still holds the switch for another copy of Switchtone. Switch Switchtone off and on in Input Monitoring."
        default: "Lets Switchtone hear when a key goes down. It never sees what you type and never saves anything."
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: RowMetrics.spacing) {
            RowSymbol(symbol: "keyboard")
                .frame(height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center) {
                    Text("Input Monitoring").font(.plex(13)).foregroundStyle(Palette.text)
                    Spacer(minLength: 8)
                    if state == .allowed { status } else { button }
                }
                .frame(minHeight: 26)
                Text(detail.keepingLastWordsTogether)
                    .font(.plex(11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state != .allowed, model.waitingForGrant {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for access")
                            .font(.plex(11))
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 4)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, RowMetrics.horizontal)
        .padding(.vertical, RowMetrics.vertical)
        .animation(style.spring, value: state)
        .animation(style.spring, value: model.waitingForGrant)
        .accessibilityElement(children: .contain)
    }

    /// The status once it is allowed: a word and a mark in the text colour.
    private var status: some View {
        statusLabel("Allowed", symbol: "checkmark", color: Palette.text)
            .accessibilityLabel("Input Monitoring is allowed")
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.plex(12))
        }
        .foregroundStyle(color)
        .transition(style.change)
    }

    @ViewBuilder
    private var button: some View {
        switch state {
        case .askable:
            PillButton(title: "Allow…", prominent: true) { model.controller?.requestAccessPrompt() }
                .accessibilityLabel("Allow Input Monitoring")
                .accessibilityHint("Shows the macOS permission prompt")
        case .denied, .stale:
            PillButton(title: "Open System Settings", prominent: true) { model.controller?.requestInputMonitoring() }
                .accessibilityHint("Opens Privacy and Security, Input Monitoring")
        case .allowed:
            EmptyView()
        }
    }
}

/// A capsule text button drawn without its own glass, so a surface never stacks glass on glass.
struct PillButton: View {
    let title: String
    let prominent: Bool
    var height: CGFloat = 26
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.plex(height > 30 ? 13 : 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .foregroundStyle(prominent ? Palette.ice : Palette.text)
                .background(Capsule().fill(prominent ? Palette.accent : Palette.surface))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome

/// The first-run window: what Switchtone does in one line, the permission it needs, Launch at login, Done.
struct OnboardingView: View {
    @Bindable var model: AppModel
    var icon: NSImage
    var done: () -> Void
    @Environment(\.windowStyle) private var style

    static let width: CGFloat = 460

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to Switchtone")
                    .font(.plex(24, weight: .light))
                    .foregroundStyle(Palette.text)
                Text("Switchtone plays the sound of a mechanical keyboard as you type.")
                    .font(.plex(13))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            PermissionRow(model: model)
                .background(GroupBackground(highContrast: style.highContrast))
            LoginSetting(model: model)
                .background(GroupBackground(highContrast: style.highContrast))

            // One accent button per surface: Allow while the permission is open, Done once it is granted.
            PillButton(title: "Done", prominent: model.permission == .granted, height: 36, fullWidth: true, action: done)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes this window. Switchtone keeps running in the background.")
        }
        .padding(24)
        .frame(width: Self.width)
        .background { Palette.ground.ignoresSafeArea() }
        .containerShape(.rect(cornerRadius: 26))
    }
}

// MARK: - Settings

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, sounds, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .sounds: "Sounds"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sounds: "speaker.wave.2"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// The window: a flat sidebar of pages, a hairline, and the page beside it under its title. The same
/// layout in every one of these apps, with the ground, text and accent from the palette.
struct SettingsRoot: View {
    let model: AppModel
    @Bindable var navigation: SettingsNavigation
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Rectangle().fill(Palette.divider).frame(width: 1)
            Group {
                switch navigation.tab {
                case .general: GeneralSettingsView(model: model)
                case .sounds: SoundsSettingsView(model: model)
                case .permissions: PermissionsSettingsView(model: model)
                case .about: AboutSettingsView(model: model)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The page's title in the unified toolbar's row. Content scrolling under it fades out.
            .safeAreaBar(edge: .top, spacing: 0) {
                Text(navigation.tab.title)
                    .font(.plex(22, weight: .light))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30)
                    .frame(height: 56)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(minWidth: 460, minHeight: 500)
        }
        .background(Palette.ground)
        .tint(Palette.accent)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsSidebarRow(tab: tab, selected: navigation.tab == tab) { navigation.tab = tab }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        // Below the traffic lights.
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
        .focusable()
        .focused($sidebarFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let all = SettingsTab.allCases
        guard let index = all.firstIndex(of: navigation.tab) else { return .ignored }
        navigation.tab = all[min(max(index + step, 0), all.count - 1)]
        return .handled
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(tab.title).font(.plex(13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Palette.text : Palette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Palette.accent.opacity(0.34) : (hovering ? Palette.surface : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One Settings tab's page: sections on the ground, drawn the way the panel is.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content() }
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// A titled group of rows in one card, with an optional footnote.
private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    var highContrast: Bool
    /// False for a section whose content draws its own surfaces (the profile cards).
    var framed = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { SectionLabel(title) }
            VStack(spacing: 0) { content() }
                .background { if framed { GroupBackground(highContrast: highContrast) } }
            if let footer {
                Text(footer)
                    .font(.plex(11))
                    .foregroundStyle(Palette.secondary)
                    .padding(.leading, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A settings row: a title, an optional line under it, and a control on the trailing side.
private struct SettingRow<Accessory: View>: View {
    var title: String
    var detail: String?
    var detailColor: Color = Palette.secondary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.plex(13)).foregroundStyle(Palette.text)
                if let detail {
                    Text(detail.keepingLastWordsTogether)
                        .font(.plex(11))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, RowMetrics.horizontal)
        .padding(.vertical, RowMetrics.vertical + 1)
        .contentShape(Rectangle())
    }
}

/// A settings row that is a switch.
private struct SettingToggle: View {
    var title: String
    var detail: String?
    var isOn: Binding<Bool>
    var hint: String?

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .tint(Palette.switchOn)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(title)
                .accessibilityHint(hint ?? "")
        }
    }
}

private struct SettingDivider: View {
    var body: some View {
        Rectangle().fill(Palette.divider).frame(height: 0.5).padding(.horizontal, RowMetrics.horizontal)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.windowStyle) private var style

    var body: some View {
        SettingsPage {
            SettingsSection(highContrast: style.highContrast) {
                SettingToggle(title: "Keyboard sounds", detail: model.statusLine, isOn: model.enabledBinding,
                              hint: "Shortcut \(KeyListener.shortcutSpoken)")
                SettingDivider()
                SettingToggle(title: "Mute when typing passwords", detail: "Silent while macOS secure keyboard entry is on.",
                              isOn: model.muteSecureBinding, hint: nil)
                SettingDivider()
                LoginSetting(model: model)
                SettingDivider()
                SettingToggle(title: "Show menu bar icon",
                              detail: "Turn it off to leave room in the menu bar. Open the app again to reach Settings.",
                              isOn: model.showMenuBarIconBinding, hint: "Everything stays in Settings when it is off")
            }
            SettingsSection(title: "Shortcut", footer: "Works in any app.", highContrast: style.highContrast) {
                SettingRow(title: "Turn the sounds on or off") {
                    HStack(spacing: 3) {
                        ForEach(KeyListener.shortcutSymbols, id: \.self) { key in
                            KeyChip(text: key, size: 12, side: 20)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(KeyListener.shortcutSpoken)
                }
            }
        }
    }
}

/// Launch at login as a settings row, with the same three states as the panel.
private struct LoginSetting: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.login {
        case .on, .off:
            SettingToggle(title: "Launch at login", detail: nil, isOn: model.loginBinding, hint: nil)
        case .needsApproval, .failed:
            SettingRow(title: "Launch at login",
                       detail: model.login == .needsApproval ? "Needs your approval in Login Items." : "macOS didn't allow this. Open Login Items to turn it on.",
                       detailColor: model.login == .needsApproval ? Palette.text : Palette.error) {
                Button { model.controller?.openLoginItems() } label: { Text("Open Login Items").foregroundStyle(Palette.text) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityHint("Opens System Settings, General, Login Items")
            }
        }
    }
}

struct SoundsSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.windowStyle) private var style

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Switches", highContrast: style.highContrast, framed: false) {
                ProfilePicker(model: model, plainSurface: style.plainSurfaces, highContrast: style.highContrast,
                              stillMotion: style.stillMotion, showsLabel: false)
                    // The cards are concentric to the section's rounded surface.
                    .containerShape(.rect(cornerRadius: 22))
            }
            SettingsSection(title: "Volume", highContrast: style.highContrast) {
                VolumeRow(model: model, highContrast: style.highContrast, stillMotion: style.stillMotion, inForm: true)
                    .padding(.horizontal, RowMetrics.horizontal)
                    .padding(.vertical, 13)
            }
            SettingsSection(title: "Output", highContrast: style.highContrast) {
                OptionRow(symbol: model.spatial ? model.routeSymbol : "speaker.wave.2", title: "3D sound",
                          detail: model.routeLine, stillMotion: style.stillMotion, isOn: model.spatialBinding)
                    .padding(.vertical, 1)
                    .soundControlsDimmed(!model.enabled)
                if model.spatial && model.engine.route.kind == .headphones {
                    RowDivider()
                    OptionRow(symbol: "person.and.background.dotted", title: "Follow head movement",
                              detail: "Keeps the keyboard in front of you when you turn", stillMotion: style.stillMotion,
                              isOn: model.headTrackingBinding)
                        .padding(.vertical, 1)
                        .soundControlsDimmed(!model.enabled)
                }
            }
            SettingsSection(title: "Feel", highContrast: style.highContrast) {
                OptionRow(symbol: "hand.tap", title: "Trackpad tick",
                          detail: model.tickAvailable ? "A tap on the trackpad with each key" : "Needs a Force Touch trackpad",
                          stillMotion: style.stillMotion, isOn: model.trackpadTickBinding)
                    .padding(.vertical, 1)
                    .disabled(!model.tickAvailable)
                    .soundControlsDimmed(!model.enabled || !model.tickAvailable)
            }
        }
        .animation(style.spring, value: model.spatial)
        .animation(style.spring, value: model.engine.route)
        .animation(style.spring, value: model.enabled)
    }
}

struct PermissionsSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.windowStyle) private var style

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Access",
                            // Only while there is a button for it to refer to.
                            footer: model.permission == .granted ? nil
                                : (model.permission == .missing && !model.accessRequested
                                   ? "macOS asks once, when you press Allow…"
                                   : "macOS asks only once. Open System Settings takes you to the switch."),
                            highContrast: style.highContrast) {
                PermissionRow(model: model)
            }
            SettingsSection(highContrast: style.highContrast) {
                SettingRow(title: "Welcome window", detail: "Show the first-run window again.") {
                    Button("Show Again") { model.controller?.resetOnboarding() }
                        .accessibilityLabel("Show welcome window again")
                        .accessibilityHint("Opens the first-run welcome window")
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: model.permission)
    }
}

/// Settings > About: what this copy is and how to use it. Help opens this page.
struct AboutSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.windowStyle) private var style

    var body: some View {
        SettingsPage {
            SettingsSection(highContrast: style.highContrast) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Switchtone").font(.plex(22, weight: .light)).foregroundStyle(Palette.text)
                        Text(model.build.map { "Version \(model.version) (\($0))" } ?? "Version \(model.version)")
                            .font(.plex(13, tabular: true)).foregroundStyle(Palette.secondary)
                        Text(AboutView.tagline).font(.plex(13)).foregroundStyle(Palette.secondary)
                        Text("© 2026 Soroush Yousefpour").font(.plex(11)).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(RowMetrics.horizontal)
                .accessibilityElement(children: .combine)
            }
            SettingsSection(title: "Using Switchtone", highContrast: style.highContrast) {
                ForEach(Array(Self.tips.enumerated()), id: \.offset) { index, tip in
                    if index > 0 { SettingDivider() }
                    SettingRow(title: tip.0) {
                        Text(tip.1).font(.plex(13)).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }

    private static let tips = [
        ("Sounds on or off", "Control-Option-Command-K"),
        ("Open the panel", "Click the menu bar symbol"),
        ("Hear a switch", "Point at its card"),
        ("Settings", "Open Switchtone from Finder or Spotlight"),
    ]
}

// MARK: - About

struct AboutView: View {
    var icon: NSImage
    var version: String
    var build: String?

    static let width: CGFloat = 340
    static let tagline = "Mechanical keyboard sounds for every key you press, in 3D."

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            Text("Switchtone")
                .font(.plex(24, weight: .light))
                .foregroundStyle(Palette.text)
            Text(build.map { "Version \(version) (\($0))" } ?? "Version \(version)")
                .font(.plex(12, tabular: true))
                .foregroundStyle(Palette.secondary)
            Text(Self.tagline)
                .font(.plex(13))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("© 2026 Soroush Yousefpour")
                .font(.plex(11))
                .foregroundStyle(Palette.secondary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 28)
        .frame(width: Self.width)
        .background { Palette.ground.ignoresSafeArea() }
        .accessibilityElement(children: .combine)
    }
}
