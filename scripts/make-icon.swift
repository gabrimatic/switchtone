// Writes the app icon as an Icon Composer document (.icon) for actool. Build it with the app's BrandMark.swift,
// the one source of the drawing (build.sh does this):
//   swiftc -parse-as-library Sources/Switchtone/BrandMark.swift scripts/make-icon.swift -o make-icon
//   ./make-icon <out.icon> [preview.png]
// The tile is the glass of the website's icon tiles: ink under a faint ice fill and a soft top sheen. It is one
// opaque layer with glass, shadow and specular off, because macOS 27 lifts a plain .icns into its own glass and
// swaps the tile for a black gradient in dark mode. The preview is that layer alone, as a square.
import AppKit

@main
enum MakeIcon {
    static let ink = CGColor(srgbRed: 0x1B / 255.0, green: 0x26 / 255.0, blue: 0x2C / 255.0, alpha: 1)
    static let ice = CGColor(srgbRed: 0xBB / 255.0, green: 0xE1 / 255.0, blue: 0xFA / 255.0, alpha: 1)
    static let accent = CGColor(srgbRed: 0x32 / 255.0, green: 0x82 / 255.0, blue: 0xB8 / 255.0, alpha: 1)
    static let side = 1024
    /// The drawing's share of the tile.
    static let markShare: CGFloat = 0.68

    static let document = """
    {
      "fill-specializations" : [
        { "value" : { "solid" : "srgb:0.10588,0.14902,0.17255,1.00000" } },
        { "appearance" : "dark", "value" : { "solid" : "srgb:0.10588,0.14902,0.17255,1.00000" } }
      ],
      "groups" : [
        {
          "layers" : [ { "glass" : false, "image-name" : "mark.png", "name" : "mark" } ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }

    """

    static func icon() -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let fill = CGGradient(colorsSpace: space, colors: [ice.copy(alpha: 0.137) ?? ice, ice.copy(alpha: 0.098) ?? ice] as CFArray, locations: [0, 1]),
              let sheen = CGGradient(colorsSpace: space, colors: [ice.copy(alpha: 0.07) ?? ice, ice.copy(alpha: 0) ?? ice] as CFArray, locations: [0, 0.45])
        else { return nil }
        let size = CGFloat(side)
        context.setFillColor(ink)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.drawLinearGradient(fill, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
        context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: size), end: .zero, options: [])
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: size * (1 - markShare) / 2, y: size * (1 - markShare) / 2)
        context.scaleBy(x: size * markShare / BrandMark.grid, y: size * markShare / BrandMark.grid)
        BrandMark.draw(in: context, ice: ice, accent: accent)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            FileHandle.standardError.write(Data("usage: make-icon <out.icon> [preview.png]\n".utf8))
            exit(2)
        }
        let out = URL(fileURLWithPath: arguments[1], isDirectory: true)
        do {
            let assets = out.appendingPathComponent("Assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try Data(document.utf8).write(to: out.appendingPathComponent("icon.json"))
            guard let layer = icon() else { throw CocoaError(.fileWriteUnknown) }
            try layer.write(to: assets.appendingPathComponent("mark.png"))
            if arguments.count > 2 { try layer.write(to: URL(fileURLWithPath: arguments[2])) }
        } catch {
            FileHandle.standardError.write(Data("icon rendering failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
