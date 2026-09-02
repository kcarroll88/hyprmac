import Foundation

public extension Tile {
    /// The tree in one line: `8317 | (8319 / 8321)` — `|` a side-by-side split,
    /// `/` a stack, first before second. Written to the log whenever a workspace
    /// changes shape, next to the cause, because "workspace 1 rearranged itself"
    /// could not be diagnosed after the fact without it.
    var shorthand: String { describe(top: true) }

    private func describe(top: Bool) -> String {
        switch self {
        case .leaf(let id): return String(id.raw)
        case .split(let axis, _, let first, let second):
            let inner = "\(first.describe(top: false)) \(axis == .horizontal ? "|" : "/") \(second.describe(top: false))"
            return top ? inner : "(\(inner))"
        }
    }
}
