@testable import BreatheKit
import Foundation
import Testing

/// The reminder dial, from the answer to the appointment it makes.
///
/// The `never` case is the one that must never break: it is the app's whole
/// privacy stance on notifications, and the way it fails is silent — a schedule
/// nobody asked for, or worse, a system permission prompt in front of somebody
/// who said no.
@MainActor
@Suite("Seeding a reminder from the onboarding dial")
struct ReminderSeedTests {
    /// Counts the asks as well as the syncs: permission belongs to the moment a
    /// schedule is created, and a seed that created none must not have asked.
    private final class NotifierSpy: ScheduleNotifying, @unchecked Sendable {
        private(set) var synced: [[Schedule]] = []
        private(set) var authorizationRequests = 0

        func requestAuthorization() async -> Bool {
            authorizationRequests += 1
            return true
        }

        func sync(_ schedules: [Schedule]) async {
            synced.append(schedules)
        }
    }

    private struct StubReader: TechniqueReading {
        let techniques: [Technique]

        func listTechniques() async throws -> [Technique] {
            techniques
        }

        func listFoundations() async throws -> [FoundationTopic] {
            []
        }
    }

    private struct AcceptingProfiles: ProfileSyncing {
        func fetch() async throws -> Profile {
            .unanswered
        }

        func update(_ profile: Profile) async throws -> Profile {
            profile
        }
    }

    private func technique(slug: String, goal: TechniqueGoal) -> Technique {
        Technique(
            id: slug,
            slug: slug,
            name: slug.capitalized,
            summary: "",
            goal: goal,
            stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 1)],
            recommendedRounds: 1
        )
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "reminder-seed-tests.\(name)")
        suite?.removePersistentDomain(forName: "reminder-seed-tests.\(name)")
        return suite ?? .standard
    }

    /// A loaded catalogue, because a seed can only name a technique the app has
    /// actually heard of.
    private func catalogue() async -> TechniqueListModel {
        let model = TechniqueListModel(
            techniques: StubReader(techniques: [
                technique(slug: "box-breathing", goal: .calm),
                technique(slug: "four-seven-eight", goal: .sleep),
                technique(slug: "bellows-breath", goal: .energy),
            ])
        )
        await model.loadIfNeeded()
        return model
    }

    /// Walks the real flow to the end with the answers given.
    private func complete(
        goals: [TechniqueGoal],
        reminders: ReminderIntensity,
        into schedules: ScheduleStore,
        defaults suite: UserDefaults
    ) async {
        let model = await OnboardingModel(
            store: ProfileStore(profiles: AcceptingProfiles(), defaults: suite),
            schedules: schedules,
            catalogue: catalogue()
        )

        model.advance()
        for goal in goals {
            model.toggle(goal)
        }
        if goals.isEmpty {
            model.skip()
        } else {
            model.advance()
        }
        model.experienceLevel = .new
        model.advance()
        model.reminderIntensity = reminders
        model.advance()
    }

    /// The promise the onboarding copy makes in as many words: leave the dial
    /// where it is and nothing happens, the permission prompt included.
    @Test("Never creates no schedule and asks for nothing")
    func neverIsSilent() async throws {
        let spy = NotifierSpy()
        let schedules = ScheduleStore(notifier: spy, defaults: defaults("never"))

        await complete(
            goals: [.sleep],
            reminders: .never,
            into: schedules,
            defaults: defaults("never-profile")
        )
        // Long enough for the fire-and-forget task an `add` would have started.
        try await Task.sleep(for: .milliseconds(50))

        #expect(schedules.schedules.isEmpty)
        #expect(spy.authorizationRequests == 0, "nobody asked for a nudge")
        #expect(spy.synced.isEmpty)
    }

    /// The other two settings, at the seam where they differ: what they ask for
    /// is a number of days, and the copy promises "an occasional nudge" and
    /// "one reminder a day" respectively.
    @Test("The dial decides how often, and only that")
    func intensityDecidesTheDays() {
        let calm = technique(slug: "box-breathing", goal: .calm)

        #expect(ReminderSeed.schedule(for: .never, technique: calm) == nil)
        #expect(ReminderSeed.schedule(for: .gentle, technique: calm)?.weekdays == [
            .monday,
            .wednesday,
            .friday,
        ])
        #expect(
            ReminderSeed.schedule(for: .daily, technique: calm)?.weekdays
                == Set(Weekday.allCases)
        )
    }

    /// A reminder to sleep at seven in the morning would be worse than none.
    @Test(
        "The hour follows the technique's goal",
        arguments: [
            (goal: TechniqueGoal.energy, hour: 7),
            (goal: .focus, hour: 12),
            (goal: .reset, hour: 15),
            (goal: .calm, hour: 18),
            (goal: .sleep, hour: 21),
        ]
    )
    func hourFollowsTheGoal(goal: TechniqueGoal, hour: Int) {
        let seeded = ReminderSeed.schedule(
            for: .daily,
            technique: technique(slug: "any", goal: goal)
        )

        #expect(seeded?.hour == hour)
        #expect(seeded?.minute == 0)
    }

    /// The whole point of the item: an answer on the dial becomes something a
    /// person can find, edit, and delete in Settings — named after the goal they
    /// picked one screen earlier.
    @Test("Finishing with a nudge leaves exactly one editable schedule")
    func finishingSeedsTheSchedule() async throws {
        let spy = NotifierSpy()
        let schedules = ScheduleStore(notifier: spy, defaults: defaults("seed"))

        await complete(
            goals: [.sleep],
            reminders: .daily,
            into: schedules,
            defaults: defaults("seed-profile")
        )

        #expect(schedules.schedules.count == 1)
        let seeded = try #require(schedules.schedules.first)
        #expect(seeded.techniqueSlug == "four-seven-eight")
        #expect(seeded.hour == 21)
        #expect(seeded.isEnabled)

        // The permission promise comes due at the store's `add`, which is where
        // every other schedule asks — onboarding adds no prompt site of its own.
        for _ in 0 ..< 200 {
            if spy.authorizationRequests > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(spy.authorizationRequests == 1)

        // A person who already keeps schedules has an arrangement of their own,
        // and the flow does not add to it.
        await complete(
            goals: [.calm],
            reminders: .daily,
            into: schedules,
            defaults: defaults("seed-profile-again")
        )
        #expect(schedules.schedules == [seeded])
    }
}
