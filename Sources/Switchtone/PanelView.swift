import SwiftUI

/// The panel under the menu bar icon. The popover is the Liquid Glass
/// surface; inside it, only the profile cards (the main controls) carry
/// their own interactive glass, grouped in one GlassEffectContainer.
struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var plainSurfaces: Bool { reduceTransparency }
    private var highContrast: Bool { contrast == .increased }
    private var stillMotion: Bool { reduceMotion }

    static let width: CGFloat = 320
    static let padding: CGFloat = 14
    /// The popover's own corner radius; inner shapes are concentric to it.
    static let panelRadius: CGFloat = 26

    /// With Reduce Motion, changes cross-fade instead of moving.
    private var spring: Animation { stillMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.3) }
    private var change: AnyTransition { stillMotion ? .opacity : AnyTransition(.blurReplace) }
    /// A notice opens downward with the rows below it, so the two never overlap mid-change.
    private var reveal: AnyTransition { AnyTransition(NoticeReveal(blur: !stillMotion)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notices
            profiles
            volume
            options
            footer
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background { (plainSurfaces ? Palette.ground : Palette.panelGround).ignoresSafeArea() }
        .containerShape(.rect(cornerRadius: Self.panelRadius))
        .animation(spring, value: model.playing)
        .animation(spring, value: model.enabled)
        .animation(spring, value: model.permission)
        .animation(spring, value: model.justGranted)
        .animation(spring, value: model.focusMuted)
        .animation(spring, value: model.engine.problem)
        .animation(spring, value: model.spatial)
        .animation(spring, value: model.engine.route)
        .animation(spring, value: model.login)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            BrandMarkView(size: 30, dimmed: !model.playing)
            VStack(alignment: .leading, spacing: 1) {
                Text("Switchtone")
                    .font(.plex(17, weight: .light))
                    .foregroundStyle(Palette.text)
                // Blur-replace, keyed by the text, so a change morphs instead of
                // stacking two sharp lines in one place.
                ZStack(alignment: .leading) {
                    Text(model.statusLine)
                        .font(.plex(12))
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                        .id(model.statusLine)
                        .transition(change)
                }
                .animation(spring, value: model.statusLine)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Toggle("Sounds", isOn: model.enabledBinding)
                .toggleStyle(.switch)
                .tint(Palette.switchOn)
                .labelsHidden()
                .accessibilityLabel("Keyboard sounds")
                .accessibilityHint("Shortcut \(KeyListener.shortcutSpoken)")
                .help("Turn the sounds on or off (\(KeyListener.shortcutDisplay))")
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        switch model.blocker {
        case .permission(let permission):
            permissionNotice(permission)
                .transition(reveal)
        case .noSound(let problem):
            Notice(symbol: "speaker.slash", isError: true, title: "No sound", message: problem) { EmptyView() }
                .transition(reveal)
        case .focus:
            Notice(symbol: "moon", title: "Paused by your Focus",
                   message: "The Switchtone Focus filter is on. Sounds come back when the Focus ends.") { EmptyView() }
                .transition(reveal)
        case nil:
            if model.justGranted {
                Notice(symbol: "checkmark.circle", title: "Switchtone can hear your keys",
                       message: "Start typing. Nothing you type is seen or stored.") { EmptyView() }
                    .transition(reveal)
            }
        }
    }

    private func permissionNotice(_ permission: AppModel.Permission) -> some View {
        let stale = permission == .stale
        let message: String
        if stale {
            message = "macOS still holds the switch for another copy of Switchtone."
        } else if model.returningInstall {
            message = "Switchtone needs it to hear when a key goes down. If Switchtone is already on in the list, switch it off, then on."
        } else {
            message = "Switchtone needs it to hear when a key goes down. It never sees what you type and never saves anything."
        }
        return Notice(symbol: "hand.raised",
                      title: stale ? "Switch Switchtone off and on in Input Monitoring" : "Allow Input Monitoring", message: message) {
            VStack(alignment: .leading, spacing: 8) {
                Button(stale ? "Open System Settings" : "Allow…") {
                    model.controller?.requestInputMonitoring()
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.accent)
                .controlSize(.regular)
                if model.waitingForGrant {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Waiting for Switchtone to be switched on")
                            .font(.plex(11))
                            .foregroundStyle(Palette.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: Profiles and volume

    private var profiles: some View {
        ProfilePicker(model: model, plainSurface: plainSurfaces, highContrast: highContrast, stillMotion: stillMotion)
    }

    private var volume: some View {
        VolumeRow(model: model, highContrast: highContrast, stillMotion: stillMotion)
    }

    // MARK: Options

    private var options: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                OptionRow(symbol: model.spatial ? model.routeSymbol : "speaker.wave.2", title: "3D sound",
                          detail: model.routeLine, stillMotion: stillMotion,
                          isOn: model.spatialBinding)
                if model.spatial && model.engine.route.kind == .headphones {
                    // The divider and the row open together, like a notice.
                    VStack(spacing: 0) {
                        RowDivider()
                        OptionRow(symbol: "person.and.background.dotted", title: "Follow head movement",
                                  detail: "Keeps the keyboard in front of you when you turn", stillMotion: stillMotion,
                                  isOn: model.headTrackingBinding)
                    }
                    .transition(reveal)
                }
            }
            .soundControlsDimmed(!model.enabled)
            RowDivider()
            OptionRow(symbol: "lock", title: "Mute when typing passwords", detail: nil, stillMotion: stillMotion,
                      isOn: model.muteSecureBinding)
            RowDivider()
            LoginRow(model: model, stillMotion: stillMotion)
        }
        .background(GroupBackground(highContrast: highContrast))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            ShortcutChip()
            Spacer(minLength: 8)
            Button {
                model.controller?.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .padding(.horizontal, 2)
                    .foregroundStyle(Palette.text)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Open Settings")
            .accessibilityLabel("Settings")
            Button {
                model.controller?.quit()
            } label: {
                Text("Quit")
                    .padding(.horizontal, 4)
                    .foregroundStyle(Palette.text)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel("Quit Switchtone")
        }
        .padding(.top, 2)
    }
}

// MARK: - Pieces

/// The three switch profiles as cards in one glass container; also used by the Settings window.
struct ProfilePicker: View {
    @Bindable var model: AppModel
    var plainSurface: Bool
    var highContrast: Bool
    var stillMotion: Bool
    /// The panel names the group itself; a Form section already has its header.
    var showsLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsLabel { SectionLabel("Switches") }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Profile.allCases) { profile in
                        ProfileCard(profile: profile, selected: model.profile == profile,
                                    playing: model.previewing == profile, plainSurface: plainSurface,
                                    highContrast: highContrast, stillMotion: stillMotion) {
                            model.controller?.choose(profile)
                        } hover: { inside in
                            if inside { model.controller?.startPreview(profile) } else { model.controller?.stopPreview() }
                        }
                    }
                }
            }
            .soundControlsDimmed(!model.enabled)
        }
    }
}

extension View {
    /// With the sounds switched off the controls that shape them stay in reach but read as inactive.
    func soundControlsDimmed(_ off: Bool) -> some View {
        opacity(off ? 0.5 : 1)
    }
}

/// The volume slider with its variable-value symbol and percentage.
struct VolumeRow: View {
    @Bindable var model: AppModel
    var highContrast: Bool
    var stillMotion: Bool
    /// Inside a settings card the row sits in the card's own surface.
    var inForm = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.volumeSymbol, variableValue: Double(model.volume))
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
                .frame(width: 22)
                .contentTransition(stillMotion ? .opacity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            Slider(value: model.volumeBinding,
                   in: 0...1) { [model] editing in
                MainActor.assumeIsolated { model.volumeEditingChanged(editing) }
            }
            .controlSize(.small)
            .tint(Palette.accent)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((model.volume * 100).rounded())) percent")
            Text("\(Int((model.volume * 100).rounded()))%")
                .font(.plex(13, tabular: true))
                .foregroundStyle(Palette.secondary)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText(value: Double(model.volume)))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, inForm ? 0 : RowMetrics.horizontal)
        .padding(.vertical, inForm ? 0 : 9)
        .background { if !inForm { GroupBackground(highContrast: highContrast) } }
        .soundControlsDimmed(!model.enabled)
    }
}

/// Launch at login with its three states: a switch, "needs your approval" and "macOS didn't allow this".
struct LoginRow: View {
    @Bindable var model: AppModel
    var stillMotion: Bool
    var inForm = false

    var body: some View {
        switch model.login {
        case .on, .off:
            OptionRow(symbol: "power", title: "Launch at login", detail: nil, stillMotion: stillMotion, inForm: inForm,
                      isOn: model.loginBinding)
        case .needsApproval:
            OptionRow(symbol: "power", title: "Launch at login", detail: "Needs your approval in Login Items",
                      detailColor: Palette.text, stillMotion: stillMotion, isOn: nil, inForm: inForm) { openLoginItemsButton }
        case .failed:
            // The system's own error goes to the log; the person gets what to do.
            OptionRow(symbol: "power", title: "Launch at login",
                      detail: "macOS didn't allow this. Open Login Items to turn it on.",
                      detailColor: Palette.error, stillMotion: stillMotion, isOn: nil, inForm: inForm) { openLoginItemsButton }
        }
    }

    private var openLoginItemsButton: some View {
        Button { model.controller?.openLoginItems() } label: { Text("Open").foregroundStyle(Palette.text) }
            .buttonStyle(.glass)
            .controlSize(.small)
            .accessibilityLabel("Open Login Items")
    }
}

/// Inserts a card the way a disclosure opens: it is unmasked from the top
/// down as the space for it grows, so the rows it pushes down never pass over
/// it, with a blur that clears as it settles.
struct NoticeReveal: Transition {
    var blur: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .mask(alignment: .top) {
                Rectangle().scaleEffect(x: 1, y: phase.isIdentity ? 1 : 0.001, anchor: .top)
            }
            .blur(radius: blur && !phase.isIdentity ? 6 : 0)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.plex(12))
            .foregroundStyle(Palette.secondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet grouped surface for rows, concentric with the panel: a faint fill and a hairline.
struct GroupBackground: View {
    var highContrast: Bool

    var body: some View {
        ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true)
            .fill(Palette.surface)
            .overlay {
                ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true)
                    .stroke(highContrast ? Palette.strongLine : Palette.hairline, lineWidth: highContrast ? 1 : 0.5)
                    .padding(0.25)
            }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 0.5)
            .padding(.leading, RowMetrics.horizontal + RowMetrics.symbol + RowMetrics.spacing)
            .padding(.trailing, RowMetrics.horizontal)
    }
}

/// The sizes every row card shares (panel, welcome window, Settings), so symbols and titles line up
/// from one card to the next.
enum RowMetrics {
    static let symbol: CGFloat = 22
    static let symbolSize: CGFloat = 14
    static let spacing: CGFloat = 10
    static let horizontal: CGFloat = 12
    static let vertical: CGFloat = 9
}

/// The monochrome line symbol at the start of a row. The symbol is keyed, so a change morphs in place.
struct RowSymbol: View {
    var symbol: String
    var stillMotion = false

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                .font(.system(size: RowMetrics.symbolSize))
                .foregroundStyle(Palette.text.opacity(0.85))
                .id(symbol)
                .transition(stillMotion ? .opacity : AnyTransition(.blurReplace))
        }
        .frame(width: RowMetrics.symbol, height: RowMetrics.symbol)
        .accessibilityHidden(true)
    }
}

/// One option: a line symbol, a title, an optional detail line, and a switch or a trailing accessory.
struct OptionRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var detail: String?
    var detailColor: Color = Palette.secondary
    /// Reduce Motion, from the panel.
    var stillMotion = false
    var isOn: Binding<Bool>?
    /// Inside a settings card the row takes the card's insets.
    var inForm = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: RowMetrics.spacing) {
            // The symbol uses the same transition as the detail text, so a route change swaps
            // both on one animation, never one after the other.
            RowSymbol(symbol: symbol, stillMotion: stillMotion)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.plex(13))
                    .foregroundStyle(Palette.text)
                if let detail {
                    // Keyed by the text and stacked, so a new route morphs in
                    // place instead of two sharp lines sharing it.
                    ZStack(alignment: .leading) {
                        Text(detail.keepingLastWordsTogether)
                            .font(.plex(11))
                            .foregroundStyle(detailColor)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(detail)
                            .transition(stillMotion ? .opacity : AnyTransition(.blurReplace))
                    }
                }
            }
            Spacer(minLength: 6)
            accessory()
            if let isOn {
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(Palette.switchOn)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityHint(detail ?? "")
            }
        }
        .padding(.horizontal, inForm ? 0 : RowMetrics.horizontal)
        .padding(.vertical, inForm ? 0 : RowMetrics.vertical)
        .contentShape(Rectangle())
    }
}

extension OptionRow where Accessory == EmptyView {
    init(symbol: String, title: String, detail: String?, detailColor: Color = Palette.secondary, stillMotion: Bool = false,
         inForm: Bool = false, isOn: Binding<Bool>?) {
        self.init(symbol: symbol, title: title, detail: detail, detailColor: detailColor, stillMotion: stillMotion, isOn: isOn,
                  inForm: inForm) { EmptyView() }
    }
}

extension String {
    /// Joins the last two words with a no-break space, so a wrapped line never
    /// ends on one word standing alone.
    var keepingLastWordsTogether: String {
        guard let space = lastIndex(of: " ") else { return self }
        var copy = self
        copy.replaceSubrange(space...space, with: "\u{00A0}")
        return copy
    }
}

/// A card at the top of the panel for something that needs attention: a quiet surface and a hairline,
/// a line symbol and words. Only a real error is drawn in red.
struct Notice<Actions: View>: View {
    var symbol: String
    var isError = false
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(isError ? Palette.error : Palette.text)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.plex(13)).foregroundStyle(Palette.text)
                    Text(message.keepingLastWordsTogether)
                        .font(.plex(11))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true)
                .fill(Palette.surface)
            ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true)
                .stroke(isError ? Palette.error.opacity(0.5) : Palette.hairline, lineWidth: 0.5)
                .padding(0.25)
        }
    }
}

/// A switch profile: the mark's keycap with a wave that tells its character, the name and the character
/// in words. Hover plays a short phrase in it. The chosen card is the one place the panel uses the accent
/// for a surface: a faint wash, a hairline and a check mark.
struct ProfileCard: View {
    var profile: Profile
    var selected: Bool
    var playing: Bool
    var plainSurface: Bool
    var highContrast: Bool
    var stillMotion = false
    var choose: () -> Void
    var hover: (Bool) -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool
    /// True from a mouse press until the card loses focus: a click is a choice, never keyboard navigation.
    @State private var pointerDriven = false

    /// The focus outline shows while the keyboard has moved focus onto the card, never after a click.
    private var showsKeyboardFocus: Bool { focused && !pointerDriven }

    private static let shape = ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true)

    /// Leaving is quick; arriving waits for it.
    private static func handover(_ arriving: Bool) -> Animation {
        arriving ? .easeOut(duration: 0.2).delay(0.12) : .easeOut(duration: 0.12)
    }

    private var glass: Glass { plainSurface ? .identity : .regular.interactive() }

    private var label: some View {
        VStack(spacing: 5) {
            ProfileGlyph(profile: profile, accented: selected || playing)
                .animation(stillMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.25), value: selected || playing)
                .padding(.bottom, 3)
            Text(profile.title)
                .font(.plex(13))
                .foregroundStyle(Palette.text)
            Text(profile.character)
                .font(.plex(11))
                .foregroundStyle(Palette.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        // Drawn in the card's own content, so it sits above the glass in every setting
        // (Reduce Transparency, Increase Contrast included) and is clipped to the card.
        // The selection is the accent wash, its hairline and the check mark; keyboard focus is only a
        // thin neutral outline outside the card (see `body`), so the two never read alike.
        // Increase Contrast also outlines the unselected cards, thinner and neutral.
        .overlay {
            ZStack {
                Self.shape.fill(Palette.selection)
                Self.shape.stroke(Palette.accent, lineWidth: 1).padding(0.5)
            }
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(false)
            // Hand-over without overlap: the old card's ring and check fade out first,
            // then the new card's fade in.
            .animation(Self.handover(selected), value: selected)
        }
        .overlay {
            Self.shape.stroke(Palette.strongLine, lineWidth: 1).padding(0.5)
                .opacity(highContrast && !selected ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .padding(8)
                .opacity(selected ? 1 : 0)
                .animation(Self.handover(selected), value: selected)
                .accessibilityHidden(true)
        }
        .contentShape(Self.shape)
    }

    @ViewBuilder
    private var plainBackground: some View {
        if plainSurface {
            Self.shape.fill(Palette.surface)
            Self.shape.stroke(Palette.hairline, lineWidth: 0.5).padding(0.25)
        }
    }

    var body: some View {
        Button(action: choose) { label }
            .buttonStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
            .background { plainBackground }
            .glassEffect(glass, in: Self.shape)
            // The keyboard focus outline: a thin neutral line outside the card, in the text colour
            // rather than the accent, so it cannot be mistaken for the selection's accent wash and check.
            // Increase Contrast makes it solid and a little thicker.
            .overlay {
                Self.shape.stroke(Palette.text.opacity(highContrast ? 1 : 0.6), lineWidth: highContrast ? 2 : 1.5)
                    .padding(-3.5)
                    .opacity(showsKeyboardFocus ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in pointerDriven = true })
            .onChange(of: focused) { _, now in if !now { pointerDriven = false } }
            .scaleEffect(hovering && !selected && !stillMotion ? 1.02 : 1)
            .animation(stillMotion ? nil : .snappy(duration: 0.2), value: hovering)
            .onHover { inside in
                hovering = inside
                hover(inside)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(profile.title), \(profile.character)")
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityHint(profile.accessibilityDescription + ". Hover to hear it.")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            // Ignoring the children drops the button's own action: VoiceOver and Accessibility
            // clients press the card through this one.
            .accessibilityAction { choose() }
    }
}

/// One small key: a character on a quiet chip.
struct KeyChip: View {
    var text: String
    var size: CGFloat = 11
    var side: CGFloat = 18

    var body: some View {
        Text(text)
            .font(.plex(size, weight: .medium))
            .foregroundStyle(Palette.text)
            .frame(minWidth: side, minHeight: side)
            .background(Palette.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The on/off shortcut as small keys.
struct ShortcutChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Toggle")
                .font(.plex(11))
                .foregroundStyle(Palette.secondary)
                .padding(.trailing, 3)
            ForEach(KeyListener.shortcutSymbols, id: \.self) { key in
                KeyChip(text: key)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Toggle sounds with \(KeyListener.shortcutSpoken)")
    }
}
