import Darwin
import Foundation

/// The one fact the Control Center control needs from the app: whether the
/// sounds are on. The app writes it on every change; the sandboxed control
/// reads it (its entitlements allow read-only access to this folder alone).
/// A plain file, because an App Group needs a provisioning profile that a
/// locally signed build does not have.
enum SharedState {
    static let controlKind = "info.gabrimatic.switchtone.toggle"
    static let folderName = "info.gabrimatic.switchtone"

    /// The real home folder, also inside the control's sandbox (where the
    /// home directory APIs answer with the container).
    static var home: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var folder: URL {
        home.appendingPathComponent("Library/Application Support/\(folderName)", isDirectory: true)
    }

    static var file: URL { folder.appendingPathComponent("state.json") }

    /// Whether the sounds are on. On when nothing has been written yet or the file cannot be read.
    static func readEnabled(from url: URL = SharedState.file) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = object["enabled"] as? Bool else { return true }
        return enabled
    }

    /// Returns false when the file could not be written (the control then shows the last state it saw).
    @discardableResult
    static func writeEnabled(_ enabled: Bool, to url: URL = SharedState.file) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
