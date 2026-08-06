import BreatheAPI
@testable import BreatheKit
import Foundation
import Testing

@Suite("Decoding proto profiles into domain types")
struct ProfileDecodingTests {
    private func protoProfile(
        goals: [Breathe_V1_TechniqueGoal] = [],
        experienceLevel: Breathe_V1_ExperienceLevel = .unspecified,
        reminderIntensity: Breathe_V1_ReminderIntensity = .never,
        intentNote: String = ""
    ) -> Breathe_V1_Profile {
        var profile = Breathe_V1_Profile()
        profile.goals = goals
        profile.experienceLevel = experienceLevel
        profile.reminderIntensity = reminderIntensity
        profile.intentNote = intentNote
        return profile
    }

    /// The Swift half of the promise the server's `an_unset_reminder_intensity_is_never`
    /// pins: an empty message has to arrive as silence. Both ends have to agree,
    /// because either one alone deciding otherwise sends a notification nobody
    /// asked for.
    @Test("An empty profile decodes to never, and to no answers")
    func anEmptyProfileIsUnanswered() throws {
        let profile = try Profile(proto: protoProfile())

        #expect(profile == .unanswered)
        #expect(profile.reminderIntensity == .never)
        #expect(profile.experienceLevel == nil)
    }

    @Test("Answers survive the round trip through the wire types")
    func roundTripsAnAnsweredProfile() throws {
        let original = Profile(
            goals: [.focus, .sleep],
            experienceLevel: .occasional,
            reminderIntensity: .gentle,
            intentNote: "I clench my jaw"
        )

        #expect(try Profile(proto: original.proto) == original)
    }

    /// Same rule as the technique decoders: a value this app cannot represent is
    /// a decode failure. Dropping the goal instead would hand someone back a
    /// profile they did not choose and cannot tell apart from one they did.
    @Test("A goal this app has no case for is rejected rather than dropped")
    func rejectsAnUnrepresentableGoal() {
        #expect(throws: ProfileRepositoryError.self) {
            try Profile(proto: protoProfile(goals: [.calm, .unspecified]))
        }
    }

    /// `unspecified` is a real answer for this field and only this field —
    /// nobody has to say how experienced they are.
    @Test("An unspecified experience level is absent, not a failure")
    func acceptsAnUnspecifiedExperienceLevel() throws {
        let profile = try Profile(proto: protoProfile(experienceLevel: .regular))
        #expect(profile.experienceLevel == .regular)

        #expect(try Profile(proto: protoProfile()).experienceLevel == nil)
    }

    @Test("Every answer a person can pick has something to show for it")
    func everyAnswerHasCopy() {
        for level in ExperienceLevel.allCases {
            #expect(!level.title.isEmpty)
            #expect(!level.detail.isEmpty)
        }
        for intensity in ReminderIntensity.allCases {
            #expect(!intensity.title.isEmpty)
            #expect(!intensity.detail.isEmpty)
        }
    }
}
