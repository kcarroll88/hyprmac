import Foundation
import HyprCore

/// Persists which window belongs on which workspace.
///
/// The whole point of a workspace is that you arrange it once. Losing that on
/// every restart makes them a novelty rather than somewhere you keep a project.
enum SessionStore {
    private static var url: URL {
        ConfigStore.directory.appendingPathComponent("session.json")
    }

    static func load() -> SessionState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return SessionState()
        }
        return state
    }

    static func save(_ state: SessionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
