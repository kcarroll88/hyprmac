import Testing
import Foundation
@testable import HyprCore

@Suite("Session restore")
struct SessionTests {
    private func pool() -> [WindowIdentity] {
        [
            .init(id: 100, bundleID: "com.mitchellh.ghostty", title: "nvim", workspace: 2),
            .init(id: 101, bundleID: "com.mitchellh.ghostty", title: "btop", workspace: 3),
            .init(id: 200, bundleID: "com.apple.Safari", title: "YouTube", workspace: 1),
        ]
    }

    @Test func recordsOfAnAppRunningSinceTheSaveAreDropped() {
        var records = pool()
        // Ghostty kept running across a WM restart (one of its windows matched by
        // id): its other record is a closed window and must not claim a new one.
        #expect(SessionMatcher.claim(id: 100, bundleID: "com.mitchellh.ghostty", title: "nvim", from: &records) == 2)
        #expect(SessionMatcher.dropRecords(ofApps: ["com.mitchellh.ghostty"], from: &records) == 1)
        #expect(SessionMatcher.claim(id: 555, bundleID: "com.mitchellh.ghostty", title: "btop", from: &records) == nil)
        // Safari was not running: its record waits for its windows as before.
        #expect(records.count == 1)
        #expect(SessionMatcher.claim(id: 556, bundleID: "com.apple.Safari", title: "YouTube", from: &records) == 1)
    }

    @Test func anUnchangedWindowIdWinsOutright() {
        var records = pool()
        // Even with a different title — the app renamed its window, it is still
        // the same window.
        #expect(SessionMatcher.claim(id: 101, bundleID: "com.mitchellh.ghostty",
                                     title: "something else", from: &records) == 3)
        #expect(records.count == 2)
    }

    @Test func bundleAndTitleSurviveAnAppRestart() {
        var records = pool()
        // New ids after relaunch, same windows.
        #expect(SessionMatcher.claim(id: 999, bundleID: "com.mitchellh.ghostty",
                                     title: "btop", from: &records) == 3)
        #expect(SessionMatcher.claim(id: 998, bundleID: "com.mitchellh.ghostty",
                                     title: "nvim", from: &records) == 2)
    }

    @Test func bundleAloneIsTheLastResort() {
        var records = pool()
        #expect(SessionMatcher.claim(id: 900, bundleID: "com.apple.Safari",
                                     title: "a page that did not exist before",
                                     from: &records) == 1)
    }

    @Test func eachRecordIsClaimedOnlyOnce() {
        // Two Safari windows must not both inherit the single remembered one.
        var records = pool()
        #expect(SessionMatcher.claim(id: 900, bundleID: "com.apple.Safari",
                                     title: "x", from: &records) == 1)
        #expect(SessionMatcher.claim(id: 901, bundleID: "com.apple.Safari",
                                     title: "y", from: &records) == nil)
    }

    @Test func anUnknownAppIsNotGuessed() {
        var records = pool()
        #expect(SessionMatcher.claim(id: 1, bundleID: "com.example.new",
                                     title: "nvim", from: &records) == nil)
        #expect(records.count == 3)
    }

    @Test func titleMatchingRequiresABundle() {
        // Two apps sharing "Untitled" must not be conflated.
        var records: [WindowIdentity] = [
            .init(id: 1, bundleID: "com.apple.freeform", title: "Untitled", workspace: 4)
        ]
        #expect(SessionMatcher.claim(id: 2, bundleID: nil, title: "Untitled", from: &records) == nil)
    }

    @Test func anEmptyTitleFallsStraightToBundle() {
        var records = pool()
        #expect(SessionMatcher.claim(id: 5, bundleID: "com.mitchellh.ghostty",
                                     title: "", from: &records) == 2)
    }

    @Test func stateRoundTripsThroughJSON() {
        let state = SessionState(windows: pool(), activeWorkspace: 3)
        let data = try! JSONEncoder().encode(state)
        #expect(try! JSONDecoder().decode(SessionState.self, from: data) == state)
    }
}
