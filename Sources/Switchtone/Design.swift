import AppKit
import CoreText
import SwiftUI

// The design language (docs/DESIGN.md) as code: the three colours, the one typeface, and the few
// shapes every surface the app draws itself is made of. Nothing else in the app names a colour or a font.

// MARK: - Colour

/// Ink, ice and accent, and alpha blends of them. Dark appearance is an ink ground with ice text; light
/// appearance is an ice-tinted paper ground with ink text; the accent is the same in both.
enum Palette {
    static let inkNS = NSColor(srgbRed: 0x1b / 255, green: 0x26 / 255, blue: 0x2c / 255, alpha: 1)
    static let iceNS = NSColor(srgbRed: 0xbb / 255, green: 0xe1 / 255, blue: 0xfa / 255, alpha: 1)
    static let accentNS = NSColor(srgbRed: 0x32 / 255, green: 0x82 / 255, blue: 0xb8 / 255, alpha: 1)
    /// Ice blended 30% into white.
    static let paperNS = NSColor(srgbRed: 235 / 255, green: 246 / 255, blue: 254 / 255, alpha: 1)

    static let ink = Color(.sRGB, red: 0x1b / 255, green: 0x26 / 255, blue: 0x2c / 255, opacity: 1)
    static let ice = Color(.sRGB, red: 0xbb / 255, green: 0xe1 / 255, blue: 0xfa / 255, opacity: 1)
    static let accent = Color(.sRGB, red: 0x32 / 255, green: 0x82 / 255, blue: 0xb8 / 255, opacity: 1)

    /// A colour that follows the appearance of the view it is drawn in.
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// The window and panel ground.
    static let ground = dynamic(dark: inkNS, light: paperNS)
    /// The panel sits on the popover's own surface; this lets a little of it through so the two read as one.
    static let panelGround = dynamic(dark: inkNS.withAlphaComponent(0.93), light: paperNS.withAlphaComponent(0.93))
    /// Primary text and symbols.
    static let text = dynamic(dark: iceNS, light: inkNS)
    /// Secondary text.
    static let secondary = dynamic(dark: iceNS.withAlphaComponent(0.68), light: inkNS.withAlphaComponent(0.68))
    /// Dimmed text and symbols (an unavailable control).
    static let tertiary = dynamic(dark: iceNS.withAlphaComponent(0.44), light: inkNS.withAlphaComponent(0.44))
    /// A quiet surface for grouped rows.
    static let surface = dynamic(dark: iceNS.withAlphaComponent(0.055), light: inkNS.withAlphaComponent(0.04))
    /// A chip or key cap.
    static let chip = dynamic(dark: iceNS.withAlphaComponent(0.10), light: inkNS.withAlphaComponent(0.07))
    /// Hairlines (ice at 0.25 in the dark appearance).
    static let hairline = dynamic(dark: iceNS.withAlphaComponent(0.25), light: inkNS.withAlphaComponent(0.20))
    /// Increase Contrast: hairlines at full text strength.
    static let strongLine = dynamic(dark: iceNS.withAlphaComponent(0.7), light: inkNS.withAlphaComponent(0.7))
    /// Dividers between rows.
    static let divider = dynamic(dark: iceNS.withAlphaComponent(0.08), light: inkNS.withAlphaComponent(0.08))
    /// A switch that is on. Neutral on purpose: the accent stays on the one selected card and the one active bar.
    static let switchOn = dynamic(dark: iceNS.withAlphaComponent(0.55), light: inkNS.withAlphaComponent(0.62))
    /// The selected card's wash.
    static let selection = accent.opacity(0.16)
    /// A real error, and only that.
    static let error = Color(nsColor: .systemRed)

    /// The ground as AppKit sees it, for window backgrounds.
    static let groundNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? inkNS : paperNS
    }
}

// MARK: - Type

/// IBM Plex Sans (SIL Open Font License, text in Resources/Fonts/OFL.txt), one variable file registered
/// with the process at launch. Native controls keep the system font; everything the app draws itself
/// uses this.
enum PlexFont {
    static let family = "IBM Plex Sans"
    static let fileName = "IBMPlexSans-Variable.ttf"
    private static let weightAxis = 0x7767_6874   // 'wght'

    /// Registers the bundled font with this process. Safe to call again. Returns false when the file is
    /// missing or macOS refuses it; the app then draws with the system font instead.
    @discardableResult
    static func register(resources: URL?) -> Bool {
        guard let url = resources?.appendingPathComponent("Fonts/\(fileName)"),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Registered earlier in this process is fine.
        if let error = error?.takeRetainedValue(), CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue { return true }
        return false
    }

    /// Whether the family resolves right now.
    static var isAvailable: Bool {
        guard let font = make(size: 12, weight: 400, tabular: false) else { return false }
        return (CTFontCopyFamilyName(font) as String) == family
    }

    /// A Plex face at a weight on the font's 100 to 700 axis, optionally with tabular figures.
    static func make(size: CGFloat, weight: CGFloat, tabular: Bool) -> CTFont? {
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: family,
            kCTFontVariationAttribute: [weightAxis: weight],
        ]
        if tabular {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ]]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

extension Font {
    /// The app's own type. Light for large headings, regular for text. Falls back to the system font if
    /// the bundled one could not be registered.
    static func plex(_ size: CGFloat, weight: PlexWeight = .regular, tabular: Bool = false) -> Font {
        if let font = PlexFontCache.font(size: size, weight: weight.value, tabular: tabular) { return Font(font) }
        return .system(size: size, weight: weight.system)
    }
}

enum PlexWeight {
    case light, regular, medium

    var value: CGFloat {
        switch self {
        case .light: 300
        case .regular: 400
        case .medium: 500
        }
    }

    var system: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        }
    }
}

/// Fonts are looked up on every view update; resolve each size and weight once.
private enum PlexFontCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fonts: [String: CTFont] = [:]

    static func font(size: CGFloat, weight: CGFloat, tabular: Bool) -> CTFont? {
        let key = "\(size)/\(weight)/\(tabular)"
        lock.lock(); defer { lock.unlock() }
        if let font = fonts[key] { return font }
        guard let font = PlexFont.make(size: size, weight: weight, tabular: tabular),
              (CTFontCopyFamilyName(font) as String) == PlexFont.family else { return nil }
        fonts[key] = font
        return font
    }
}

// MARK: - The mark

/// The app's mark, drawn from `BrandMark` (the one source of the icon and the menu bar symbol): the
/// keyboard in the text colour, the pressed key in accent. Switched off, the same mark is shown dimmed.
struct BrandMarkView: View {
    var size: CGFloat = 26
    var dimmed = false

    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / BrandMark.grid
            let transform = CGAffineTransform(scaleX: unit, y: unit)
            for path in BrandMark.icePaths() {
                context.fill(Path(path).applying(transform), with: .color(Palette.text), style: FillStyle(eoFill: true))
            }
            for path in BrandMark.accentPaths() {
                context.fill(Path(path).applying(transform), with: .color(Palette.accent))
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.4 : 1)
        .accessibilityHidden(true)
    }
}

/// A switch profile as a keycap with a wave that tells the character: a smooth wave for
/// Linear, a single bump for Tactile, a sharp click for Clicky. The wave takes the accent when the
/// profile is chosen or playing.
struct ProfileGlyph: View {
    var profile: Profile
    var accented: Bool
    var size: CGFloat = 30
    var lineWidth: CGFloat = 1.7

    static func wave(_ profile: Profile) -> CGPath {
        switch profile {
        case .linear:
            return BrandMark.wavePath()
        case .tactile:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 5.6, y: 9))
            path.addLine(to: CGPoint(x: 6.6, y: 9))
            path.addCurve(to: CGPoint(x: 8, y: 6.2), control1: CGPoint(x: 7.3, y: 9), control2: CGPoint(x: 7.2, y: 6.2))
            path.addCurve(to: CGPoint(x: 9.4, y: 9), control1: CGPoint(x: 8.8, y: 6.2), control2: CGPoint(x: 8.7, y: 9))
            path.addLine(to: CGPoint(x: 10.4, y: 9))
            return path
        case .clicky:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 5.6, y: 8))
            path.addLine(to: CGPoint(x: 6.9, y: 8))
            path.addLine(to: CGPoint(x: 7.7, y: 6))
            path.addLine(to: CGPoint(x: 8.5, y: 10))
            path.addLine(to: CGPoint(x: 9.3, y: 8))
            path.addLine(to: CGPoint(x: 10.4, y: 8))
            return path
        }
    }

    private func strokes(_ draw: @escaping (GraphicsContext, CGAffineTransform, StrokeStyle) -> Void) -> some View {
        Canvas { context, canvas in
            let unit = canvas.width / 12
            let transform = CGAffineTransform(scaleX: unit, y: unit).translatedBy(x: -2, y: -2)
            draw(context, transform, StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    var body: some View {
        // The accent wave is its own layer: a Canvas repaints at once, an opacity fades.
        let wave = Path(Self.wave(profile))
        return ZStack {
            strokes { context, transform, stroke in
                context.stroke(Path(BrandMark.keycapPath()).applying(transform), with: .color(Palette.text.opacity(0.85)), style: stroke)
                context.stroke(wave.applying(transform), with: .color(Palette.text), style: stroke)
            }
            strokes { context, transform, stroke in
                context.stroke(wave.applying(transform), with: .color(Palette.accent), style: stroke)
            }
            .opacity(accented ? 1 : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
