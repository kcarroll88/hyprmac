import Testing
@testable import HyprCore

@Suite("Animation config")
struct AnimationConfigTests {
    @Test func defaultsToAQuarterSecondCrossfade() {
        let config = Config()
        #expect(config.animationsEnabled)
        #expect(config.animationDuration == 0.25)
    }

    @Test func durationIsGivenInMilliseconds() {
        let (config, diagnostics) = ConfigParser.parse("""
        animations {
            enabled = true
            duration = 180
        }
        """)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(config.animationDuration == 0.18)
    }

    @Test func canBeTurnedOff() {
        let (config, _) = ConfigParser.parse("animations {\n enabled = false\n}")
        #expect(!config.animationsEnabled)
    }

    @Test func aRunawayDurationIsClamped() {
        // A typo like 2500 must not leave the screen covered for seconds.
        let (config, _) = ConfigParser.parse("animations {\n duration = 2500\n}")
        #expect(config.animationDuration == 1.0)
        let (negative, _) = ConfigParser.parse("animations {\n duration = -40\n}")
        #expect(negative.animationDuration == 0)
    }
}
