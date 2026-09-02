import Foundation

/// Persists workspace names renamed at runtime.
///
/// Kept beside the config rather than written into it: the config is hand-authored
/// and full of comments, and rewriting it to record a rename would mangle
/// somebody's file. Config names are the defaults; anything renamed here wins.
struct WorkspaceNameStore {
    private static var url: URL {
        ConfigStore.directory.appendingPathComponent("workspace-names.json")
    }

    static func load() -> [Int: String] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let index = Int(pair.key) { result[index] = pair.value }
        }
    }

    static func save(_ names: [Int: String]) {
        let raw = names.reduce(into: [String: String]()) { $0["\($1.key)"] = $1.value }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
