import Testing
@testable import HyprCore

@Suite("Workspace reordering")
struct WorkspaceOrderTests {
    @Test func movingForwardSlidesTheOthersBack() {
        // Drag 1 onto slot 4: 2, 3, 4 each shift back one, 1 lands fourth.
        #expect(WorkspaceOrder.moving(from: 1, to: 4, count: 5) == [2, 3, 4, 1, 5])
    }

    @Test func movingBackwardSlidesTheOthersForward() {
        #expect(WorkspaceOrder.moving(from: 4, to: 1, count: 5) == [4, 1, 2, 3, 5])
    }

    @Test func adjacentMoveIsASwap() {
        #expect(WorkspaceOrder.moving(from: 2, to: 3, count: 4) == [1, 3, 2, 4])
    }

    @Test func aNoOpDragLeavesTheOrderAlone() {
        #expect(WorkspaceOrder.moving(from: 3, to: 3, count: 5) == [1, 2, 3, 4, 5])
    }

    @Test func outOfRangeIsIgnoredRatherThanScrambling() {
        // A stray drop must never permute anything.
        #expect(WorkspaceOrder.moving(from: 0, to: 2, count: 4) == [1, 2, 3, 4])
        #expect(WorkspaceOrder.moving(from: 2, to: 9, count: 4) == [1, 2, 3, 4])
        #expect(WorkspaceOrder.moving(from: -1, to: 1, count: 4) == [1, 2, 3, 4])
    }

    @Test func everyWorkspaceSurvivesEveryMove() {
        for from in 1...6 {
            for to in 1...6 {
                let order = WorkspaceOrder.moving(from: from, to: to, count: 6)
                #expect(Set(order) == Set(1...6), "\(from)->\(to) lost or duplicated a workspace")
                #expect(order.count == 6)
            }
        }
    }

    @Test func youCanFollowTheWorkspaceYouWereOn() {
        let order = WorkspaceOrder.moving(from: 1, to: 4, count: 5)
        #expect(WorkspaceOrder.position(of: 1, in: order) == 4)
        #expect(WorkspaceOrder.position(of: 2, in: order) == 1)
        #expect(WorkspaceOrder.position(of: 99, in: order) == nil)
    }

    @Test func aSingleWorkspaceCannotBeReordered() {
        #expect(WorkspaceOrder.moving(from: 1, to: 1, count: 1) == [1])
    }
}
