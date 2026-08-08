import Foundation
@testable import OndKit
import Testing

/// A technique with everything left at its simplest but the two fields these
/// suites turn on: the slug a payload names, and the tier that decides where a
/// tap on it lands.
private func technique(slug: String, requires: SubscriptionTier = .free) -> Technique {
    Technique(
        id: slug,
        slug: slug,
        name: slug,
        summary: "",
        goal: .calm,
        stages: [Stage(phases: [Phase(kind: .inhale, duration: .seconds(4))], cycles: 1)],
        recommendedRounds: 1,
        requires: requires
    )
}

@Suite("What a notification carries")
struct NotificationPayloadTests {
    /// The key is written out rather than read off `NotificationPayload`,
    /// deliberately. The spelling is the contract between a reminder placed
    /// today and the launch that opens it next Tuesday, so a test that asked the
    /// type for it would pass through the one rename that breaks every reminder
    /// already sitting in the notification centre.
    private static let key = "techniqueSlug"

    @Test("The slug survives the round trip through userInfo")
    func roundTrips() throws {
        let sent = NotificationPayload(techniqueSlug: "box-breathing")

        #expect(sent.userInfo == [Self.key: "box-breathing"])
        #expect(try #require(NotificationPayload(userInfo: sent.userInfo)) == sent)
    }

    @Test("A notification carrying nothing is not a route")
    func emptyUserInfoIsNoRoute() {
        #expect(NotificationPayload(userInfo: [:]) == nil)
    }

    /// Every shape the dictionary can arrive in that a force-unwrap would have
    /// crashed on: a reminder placed before this shipped, a value APNs serialised
    /// as something other than a string, and a slug that is present but says
    /// nothing.
    @Test("A payload that is absent, empty, or the wrong type is not a route")
    func malformedUserInfoIsNoRoute() {
        let wrongKey: [AnyHashable: Any] = ["exercise": "box-breathing"]
        let wrongType: [AnyHashable: Any] = [Self.key: 4]
        let empty: [AnyHashable: Any] = [Self.key: ""]

        #expect(NotificationPayload(userInfo: wrongKey) == nil)
        #expect(NotificationPayload(userInfo: wrongType) == nil)
        #expect(NotificationPayload(userInfo: empty) == nil)
    }
}

@Suite("Where a tapped notification goes")
struct NotificationDestinationTests {
    private let free = technique(slug: "box-breathing")
    private let paid = technique(slug: "long-box-breathing", requires: .plus)

    private var catalogue: [Technique] {
        [free, paid]
    }

    private func destination(
        _ slug: String,
        tier: SubscriptionTier
    ) -> NotificationDestination? {
        NotificationDestination(
            NotificationPayload(techniqueSlug: slug),
            in: catalogue,
            tier: tier
        )
    }

    @Test("An exercise this tier opens goes to its session screen")
    func unlockedGoesToTheSession() {
        #expect(destination("box-breathing", tier: .free) == .session(free))
    }

    @Test("An exercise this tier does not open goes to the offer, never the session")
    func lockedGoesToTheOffer() {
        #expect(destination("long-box-breathing", tier: .free) == .offer(paid))
    }

    /// The same standing reminder, before and after a subscription — the one
    /// case that makes the lock a routing decision rather than a property of the
    /// schedule, which was written when the person was on a different tier.
    @Test("Subscribing changes where the same reminder lands")
    func subscribingOpensTheSession() {
        #expect(destination("long-box-breathing", tier: .plus) == .session(paid))
    }

    /// The catalogue is served rather than bundled, so a slug can outlive the
    /// technique it names. Nowhere is an answer; a crash is not.
    @Test("A slug the catalogue no longer has goes nowhere")
    func unknownSlugGoesNowhere() {
        #expect(destination("retired-exercise", tier: .plus) == nil)
        #expect(destination("", tier: .plus) == nil)
    }
}

@MainActor
@Suite("The road a tap waits on")
struct NotificationRouterTests {
    @Test("A request waits until something takes it")
    func theRequestWaits() {
        let router = NotificationRouter()
        #expect(router.pending == nil)

        router.request(NotificationPayload(techniqueSlug: "box-breathing"))

        #expect(router.pending == NotificationPayload(techniqueSlug: "box-breathing"))
    }

    /// What stops a dismissed session screen being reopened by the request that
    /// opened it, and what stops an unresolvable request being retried on every
    /// pass the chrome makes.
    @Test("Taking a request yields it once")
    func takingConsumes() {
        let router = NotificationRouter()
        router.request(NotificationPayload(techniqueSlug: "box-breathing"))

        #expect(router.take() == NotificationPayload(techniqueSlug: "box-breathing"))
        #expect(router.pending == nil)
        #expect(router.take() == nil)
    }

    @Test("The most recent tap wins")
    func theLastTapWins() {
        let router = NotificationRouter()
        router.request(NotificationPayload(techniqueSlug: "box-breathing"))
        router.request(NotificationPayload(techniqueSlug: "coherent-breathing"))

        #expect(router.take() == NotificationPayload(techniqueSlug: "coherent-breathing"))
    }
}
