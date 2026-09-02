import Testing
import Foundation
@testable import HyprCore

@Suite("Config parsing")
struct ConfigTests {
    @Test func parsesSectionsIntoSettings() {
        let (config, diagnostics) = ConfigParser.parse("""
        general {
            gaps_in = 8
            gaps_out = 20
            border_size = 3
        }
        """)
        #expect(config.gaps.inner == 8)
        #expect(config.gaps.outer == 20)
        #expect(config.borderSize == 3)
        #expect(diagnostics.isEmpty)
    }

    @Test func variableExpansion() {
        let (config, _) = ConfigParser.parse("""
        $mod = ALT
        bind = $mod, H, movefocus, l
        """)
        #expect(config.binds.first?.modifiers == .option)
    }

    @Test func longerVariableNamesWinOverPrefixes() {
        let (config, _) = ConfigParser.parse("""
        $mod = ALT
        $modshift = ALT SHIFT
        bind = $modshift, H, movefocus, l
        """)
        #expect(config.binds.first?.modifiers == [.option, .shift])
    }

    @Test func commentsAndBlankLinesIgnored() {
        let (config, diagnostics) = ConfigParser.parse("""
        # a comment

        general {
            gaps_in = 5  # trailing comment
        }
        """)
        #expect(config.gaps.inner == 5)
        #expect(diagnostics.isEmpty)
    }

    @Test func bindDispatchers() {
        let (config, diagnostics) = ConfigParser.parse("""
        bind = SUPER, Q, killactive
        bind = ALT SHIFT, L, movewindow, r
        bind = CTRL, 1, workspace, 1
        bind = ALT, Return, exec, open -a Ghostty --args --title=x
        bind = ALT CTRL, H, resizeactive, -40 0
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(config.binds.count == 5)
        #expect(config.binds[0].dispatcher == .killActive)
        #expect(config.binds[0].modifiers == .command)
        #expect(config.binds[1].dispatcher == .moveWindow(.right))
        #expect(config.binds[2].dispatcher == .workspace(1))
        #expect(config.binds[3].dispatcher == .exec("open -a Ghostty --args --title=x"))
        #expect(config.binds[4].dispatcher == .resizeActive(dx: -40, dy: 0))
    }

    @Test func execArgumentKeepsItsCommas() {
        // The dispatcher argument is the rest of the line, commas and all.
        let (config, _) = ConfigParser.parse(#"bind = ALT, E, exec, sh -c "echo a,b,c""#)
        #expect(config.binds.first?.dispatcher == .exec(#"sh -c "echo a,b,c""#))
    }

    @Test func colorFormats() {
        let (hex, _) = ConfigParser.parse("general {\n col.active_border = 0xff89b4fa\n}")
        #expect(hex.activeBorderColor == 0xFF89B4FA)

        let (rgba, _) = ConfigParser.parse("general {\n col.active_border = rgba(89b4faff)\n}")
        #expect(rgba.activeBorderColor == 0xFF89B4FA)

        let (rgb, _) = ConfigParser.parse("general {\n col.active_border = rgb(89b4fa)\n}")
        #expect(rgb.activeBorderColor == 0xFF89B4FA)
    }

    @Test func diagnosticsReportBadInput() {
        let (_, diagnostics) = ConfigParser.parse("""
        bind = ALT, NotAKey, killactive
        bind = ALT, H, notadispatcher
        general {
            nonsense = 1
        """)
        // unknown key, unknown dispatcher, unknown setting, unclosed section
        #expect(diagnostics.count == 4)
        #expect(diagnostics[0].message.contains("unknown key"))
        #expect(diagnostics[1].message.contains("unknown dispatcher"))
        #expect(diagnostics.contains { $0.message.contains("unknown setting") })
        #expect(diagnostics.contains { $0.message.contains("unclosed section") })
    }

    @Test func unmatchedBraceIsReported() {
        let (_, diagnostics) = ConfigParser.parse("}")
        #expect(diagnostics.contains { $0.message.contains("unmatched") })
    }

    @Test func shippedDefaultConfigIsValid() {
        // Whatever we write into a new user's home has to parse without complaint.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try! String(contentsOf: root.appendingPathComponent("Sources/hyprmac/ConfigStore.swift"),
                                encoding: .utf8)
        guard let start = source.range(of: "defaultConfig = \"\"\"\n"),
              let end = source.range(of: "\n    \"\"\"", range: start.upperBound..<source.endIndex) else {
            Issue.record("could not locate the defaultConfig literal")
            return
        }
        // Strip the 4-space literal indentation Swift would remove at runtime.
        let literal = source[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : $0 }
            .joined(separator: "\n")

        let (config, diagnostics) = ConfigParser.parse(literal)
        #expect(diagnostics.isEmpty, "default config has errors: \(diagnostics)")
        #expect(config.binds.count > 20)
    }
}

@Suite("Double taps")
struct DoubleTapTests {
    @Test func parsesAModifierAndADispatcher() {
        let (config, diagnostics) = ConfigParser.parse("doubletap = ALT, exec, open wisper://listen")
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(config.doubleTaps == [DoubleTap(modifiers: .option, dispatcher: .exec("open wisper://listen"))])
    }

    @Test func aTapWithoutAModifierIsRefused() {
        let (config, diagnostics) = ConfigParser.parse("doubletap = , exec, open wisper://listen")
        #expect(config.doubleTaps.isEmpty)
        #expect(diagnostics.count == 1)
    }
}

import Testing
@testable import HyprCore

@Suite("Sided double taps") struct SidedDoubleTapTests {
    @Test func rightControlCarriesItsKeyCode() {
        let (config, diagnostics) = ConfigParser.parse("doubletap = RCTRL, exec, open -g wisper://listen\n")
        #expect(diagnostics.isEmpty)
        #expect(config.doubleTaps.count == 1)
        #expect(config.doubleTaps.first?.modifiers == Modifiers.control)
        #expect(config.doubleTaps.first?.keyCode == 62)
    }

    @Test func plainModifierMeansEitherSide() {
        let (config, _) = ConfigParser.parse("doubletap = SUPER, exec, x\n")
        #expect(config.doubleTaps.first?.modifiers == Modifiers.command)
        #expect(config.doubleTaps.first?.keyCode == nil)
    }
}
