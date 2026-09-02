import Foundation

/// Permutations for reordering workspaces.
///
/// Dragging a workspace to a new position is a *move*, not a swap: dropping the
/// first onto the fourth slot should slide the ones in between back by one, the
/// way reordering a list works everywhere else. Swapping would leave the two you
/// dragged past exactly where they were.
public enum WorkspaceOrder {
    /// The workspace indices in their new order, where element `i` names the
    /// workspace that should become workspace `i + 1`.
    ///
    /// Returns the identity order for a no-op or an out-of-range request, so a
    /// stray drag can never scramble the layout.
    public static func moving(from source: Int, to destination: Int, count: Int) -> [Int] {
        let identity = Array(1...max(1, count))
        guard count > 1,
              identity.indices.contains(source - 1),
              identity.indices.contains(destination - 1),
              source != destination else { return identity }

        var order = identity
        let moved = order.remove(at: source - 1)
        order.insert(moved, at: destination - 1)
        return order
    }

    /// Where a workspace ends up after a reorder: its position in `order`, as a
    /// 1-based index. Used to follow the workspace you were on.
    public static func position(of workspace: Int, in order: [Int]) -> Int? {
        order.firstIndex(of: workspace).map { $0 + 1 }
    }
}
