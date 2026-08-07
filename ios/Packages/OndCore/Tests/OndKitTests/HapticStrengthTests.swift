import OndKit
import Testing

/// The mapping between an authored haptic value and what the engine is handed.
///
/// Worth pinning for two reasons. `standard` has to be exactly identity — it is
/// the feel every pattern in `HapticController` was tuned against, and a default
/// that quietly re-tuned them would be a change nobody asked for. And every
/// result has to stay inside 0...1, because CoreHaptics does not clamp for you:
/// an out-of-range parameter is a pattern that fails to build, which on a phase
/// boundary is a cue that silently never plays.
@Suite("Haptic strength")
struct HapticStrengthTests {
    /// The values `HapticController` actually authors, so the assertions below
    /// are about the patterns that exist rather than about arbitrary numbers.
    private let authored: [Float] = [0.08, 0.12, 0.45, 0.8, 0.85, 0.9, 1]

    @Test("Standard leaves every authored value exactly as written")
    func standardIsIdentity() {
        for value in authored {
            #expect(HapticStrength.standard.intensity(value) == value)
            #expect(HapticStrength.standard.sharpness(value) == value)
        }
    }

    @Test("Nothing ever leaves the range the engine accepts")
    func staysInRange() {
        for strength in HapticStrength.allCases {
            for value in authored {
                #expect((0 ... 1).contains(strength.intensity(value)))
                #expect((0 ... 1).contains(strength.sharpness(value)))
            }
        }
    }

    /// The point of the setting: at the top of an inhale, Strong has to be
    /// meaningfully more than Standard and Gentle meaningfully less.
    @Test("The three steps are ordered, and distinguishable at the peak")
    func stepsAreOrdered() {
        let peak: Float = 0.85

        #expect(HapticStrength.gentle.intensity(peak) < HapticStrength.standard.intensity(peak))
        #expect(HapticStrength.standard.intensity(peak) < HapticStrength.strong.intensity(peak))
        #expect(HapticStrength.strong.sharpness(0.3) > HapticStrength.standard.sharpness(0.3))
        #expect(HapticStrength.gentle.sharpness(0.3) < HapticStrength.standard.sharpness(0.3))
    }

    /// Intensity alone cannot deliver "stronger" — the patterns are authored up
    /// to 0.9, so scaling has a tenth of headroom before it clips. Strong has to
    /// find the rest on the sharpness axis, and this is what says so.
    @Test("Strong is more than a clipped intensity")
    func strongLeansOnSharpness() {
        #expect(HapticStrength.strong.intensity(0.9) == 1, "the scale clips at the top")
        #expect(
            HapticStrength.strong.sharpness(0.8) > 0.8,
            "so the extra has to come from the crispness of the tap"
        )
    }

    /// A quieter tap, not an absent one: a phase whose cue scaled to nothing
    /// would be a boundary the person never feels, which is not what somebody
    /// choosing Gentle asked for.
    @Test("Gentle never scales a cue away entirely")
    func gentleStaysAudible() {
        #expect(HapticStrength.gentle.intensity(0.05) > 0)
        #expect(HapticStrength.gentle.intensity(0.001) > 0)
    }
}
