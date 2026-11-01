import AppKit
import os

/// Force Touch trackpad feedback, used the way the system uses it: a detent
/// at a slider's ends, a tap when a choice lands. The trackpad's own
/// "Force Click and haptic feedback" setting still applies.
enum Haptics {
    enum Kind { case generic, alignment, levelChange }

    /// Every call is logged at debug level.
    private static let log = Logger(subsystem: "info.gabrimatic.switchtone", category: "haptics")

    static var available: Bool { true }

    @MainActor
    static func perform(_ kind: Kind) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch kind {
        case .generic: pattern = .generic
        case .alignment: pattern = .alignment
        case .levelChange: pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        log.debug("haptic \(String(describing: kind), privacy: .public)")
    }
}

/// The menu bar symbol: `BrandMark` as a template image, so the menu bar tints it. Off is the same
/// symbol shown disabled; a problem cuts an exclamation mark out of the board.
enum StatusIcon {
    enum State: Equatable { case on, off, attention }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ state: State) -> NSImage {
        switch state {
        case .on: BrandMark.menuBarImage(description: "Switchtone, on")
        case .off: BrandMark.menuBarImage(description: "Switchtone, off")
        case .attention: BrandMark.menuBarImage(description: "Switchtone, needs attention", attention: true)
        }
    }
}
