import Foundation

/// The sound families Switchtone distinguishes. Each has its own press and release samples.
/// Shift has no recordings of its own: it uses the modifier samples with a stabilizer rattle.
enum KeyClass: String, CaseIterable, Sendable {
    case key, space, enter, backspace, modifier, shift

    init(keyCode: Int64) {
        switch keyCode {
        case 49: self = .space
        case 36, 76: self = .enter            // return, keypad enter
        case 51, 117: self = .backspace       // delete, forward delete
        case 56, 60: self = .shift            // left and right shift
        case 54...63: self = .modifier
        default: self = .key
        }
    }

    /// A fixed slot number, for tables the key path reads.
    var index: Int {
        switch self {
        case .key: return 0
        case .space: return 1
        case .enter: return 2
        case .backspace: return 3
        case .modifier: return 4
        case .shift: return 5
        }
    }

    /// Long keys sit on a wire stabilizer, which adds a faint metallic rattle.
    var isStabilized: Bool {
        switch self {
        case .space, .enter, .backspace, .shift: return true
        case .key, .modifier: return false
        }
    }

    /// The recorded family a class plays from.
    var sampleFamily: String {
        self == .shift ? KeyClass.modifier.rawValue : rawValue
    }
}

enum Profile: String, CaseIterable, Sendable, Identifiable {
    case linear, tactile, clicky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: return "Linear"
        case .tactile: return "Tactile"
        case .clicky: return "Clicky"
        }
    }

    var character: String {
        switch self {
        case .linear: return "Creamy"
        case .tactile: return "Thocky"
        case .clicky: return "Crisp"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .linear: return "Linear switches, a deep, short and muted sound"
        case .tactile: return "Tactile switches, a rounder bump with a mid-range knock"
        case .clicky: return "Clicky switches, a bright click over a solid body"
        }
    }
}

/// Device-dependent modifier bits (IOLLEvent.h, NX_DEVICE*KEYMASK) plus the
/// device-independent bits for caps lock and fn, keyed by the modifier keycode.
/// A flagsChanged event is a press when the key's bit is set afterwards.
enum ModifierBits {
    static func mask(forKeyCode code: Int64) -> UInt64? {
        switch code {
        case 59: return 0x0000_0001   // left control
        case 56: return 0x0000_0002   // left shift
        case 60: return 0x0000_0004   // right shift
        case 55: return 0x0000_0008   // left command
        case 54: return 0x0000_0010   // right command
        case 58: return 0x0000_0020   // left option
        case 61: return 0x0000_0040   // right option
        case 62: return 0x0000_2000   // right control
        case 57: return 0x0001_0000   // caps lock (state, not key position)
        case 63: return 0x0080_0000   // fn
        default: return nil
        }
    }
}

/// Where each key sits on a MacBook ANSI keyboard, in key units: the column is
/// the key's centre from the left edge, the row counts from the function row
/// (0) to the space row (5). Keys of external keyboards that a MacBook lacks
/// (keypad, navigation block) sit to the right of the main block.
enum KeyLayout {
    struct Spot: Equatable, Sendable {
        var column: Double
        var row: Double
    }

    /// Width of the main block in key units; its centre is the keyboard's centre.
    static let width = 14.5
    static let center = Spot(column: width / 2, row: 2.5)

    private static let spots: [Int64: Spot] = {
        var map: [Int64: Spot] = [:]
        func row(_ r: Double, _ keys: [(Int64, Double)]) { for (code, column) in keys { map[code] = Spot(column: column, row: r) } }
        // Function row: Esc, then F1 to F12.
        let fKeys: [Int64] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        row(0, [(53, 0.75)] + fKeys.enumerated().map { ($0.element, 1.5 + 1.03 * (Double($0.offset) + 0.5)) })
        row(1, [(50, 0.5), (18, 1.5), (19, 2.5), (20, 3.5), (21, 4.5), (23, 5.5), (22, 6.5), (26, 7.5),
                (28, 8.5), (25, 9.5), (29, 10.5), (27, 11.5), (24, 12.5), (51, 13.75)])
        row(2, [(48, 0.75), (12, 2), (13, 3), (14, 4), (15, 5), (17, 6), (16, 7), (32, 8), (34, 9),
                (31, 10), (35, 11), (33, 12), (30, 13), (42, 14)])
        row(3, [(57, 0.875), (0, 2.25), (1, 3.25), (2, 4.25), (3, 5.25), (5, 6.25), (4, 7.25), (38, 8.25),
                (40, 9.25), (37, 10.25), (41, 11.25), (39, 12.25), (36, 13.625)])
        row(4, [(56, 1.125), (6, 2.75), (7, 3.75), (8, 4.75), (9, 5.75), (11, 6.75), (45, 7.75), (46, 8.75),
                (43, 9.75), (47, 10.75), (44, 11.75), (60, 13.375)])
        row(5, [(63, 0.5), (59, 1.5), (58, 2.5), (55, 3.625), (49, 6.75), (54, 9.875), (61, 11), (62, 11),
                (123, 12), (124, 14)])
        map[126] = Spot(column: 13, row: 4.75)   // up arrow, half height
        map[125] = Spot(column: 13, row: 5.25)   // down arrow
        // External keyboards: navigation block and keypad to the right.
        row(1, [(114, 15.5), (115, 16.5), (116, 17.5), (71, 19), (81, 20), (75, 21), (67, 22)])
        row(2, [(117, 15.5), (119, 16.5), (121, 17.5), (89, 19), (91, 20), (92, 21), (78, 22)])
        row(3, [(86, 19), (87, 20), (88, 21), (69, 22)])
        row(4, [(83, 19), (84, 20), (85, 21), (76, 22)])
        row(5, [(82, 19.5), (65, 21)])
        return map
    }()

    static func spot(forKeyCode code: Int64) -> Spot {
        spots[code] ?? center
    }

    static var knownKeyCodes: [Int64] { Array(spots.keys) }
}
