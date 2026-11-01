import AppKit

/// Switchtone's mark: a keyboard with one key pressed in accent.
/// One drawing on a 24-unit grid, y down: solid ice, one accent part, detail cut out of it.
/// `scripts/make-icon.swift` paints it on the app icon's tile and `menuBarImage` draws it as a
/// template, so the two can never differ.
enum BrandMark {
    static let grid: CGFloat = 24

    private static let keyWidth: CGFloat = 3.1, keyGap: CGFloat = 1, firstKey: CGFloat = 3.8

    private static func key(_ column: Int, _ row: Int) -> CGPath {
        rounded(firstKey + CGFloat(column) * (keyWidth + keyGap), 5.6 + CGFloat(row) * 4.2, keyWidth, 3.1, 0.7)
    }

    private static var board: CGPath { rounded(0.8, 3, 22.4, 18, 3.8) }

    /// The ice part, filled even-odd so the keys are cut out.
    static func icePaths() -> [CGPath] {
        var parts = [board, rounded(6.6, 14.3, 10.8, 3.3, 0.9)]
        for row in 0..<2 {
            for column in 0..<4 { parts.append(key(column, row)) }
        }
        return [merged(parts)]
    }

    /// The one accent part: the pressed key.
    static func accentPaths() -> [CGPath] { [key(3, 0)] }

    /// The board with an exclamation mark cut out, when Switchtone needs attention.
    static func attentionPath() -> CGPath {
        merged([board, rounded(10.9, 6, 2.2, 7.6, 1.1), rounded(10.9, 15, 2.2, 2.4, 1.1)])
    }

    /// One keycap, for the switch profiles: each carries a wave that tells its character. 16-unit grid.
    static func keycapPath() -> CGPath {
        CGPath(roundedRect: CGRect(x: 4.5, y: 4.5, width: 7, height: 7), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
    }

    /// The smooth wave of the Linear profile. 16-unit grid.
    static func wavePath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5.8, y: 8))
        path.addCurve(to: CGPoint(x: 8, y: 8), control1: CGPoint(x: 6.8, y: 5.5), control2: CGPoint(x: 7, y: 5.5))
        path.addCurve(to: CGPoint(x: 10.2, y: 8), control1: CGPoint(x: 9, y: 10.5), control2: CGPoint(x: 9.2, y: 10.5))
        return path
    }

    /// Paints the mark on a context whose unit is one grid unit, y down. Without an accent colour the
    /// accent part stays cut out.
    static func draw(in context: CGContext, ice: CGColor, accent: CGColor?) {
        context.setFillColor(ice)
        for path in icePaths() {
            context.addPath(path)
            context.fillPath(using: .evenOdd)
        }
        guard let accent else { return }
        context.setFillColor(accent)
        for path in accentPaths() {
            context.addPath(path)
            context.fillPath()
        }
    }

    /// The menu bar image: the same drawing in one colour, as a template so macOS tints it.
    /// The pressed key stays cut out, since one colour cannot tell it from the board.
    static func menuBarImage(description: String, attention: Bool = false) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: side)
            context.scaleBy(x: side / grid, y: -side / grid)
            if attention {
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(attentionPath())
                context.fillPath(using: .evenOdd)
            } else {
                draw(in: context, ice: NSColor.black.cgColor, accent: nil)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    private static func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func merged(_ paths: [CGPath]) -> CGPath {
        let path = CGMutablePath()
        paths.forEach { path.addPath($0) }
        return path
    }
}
