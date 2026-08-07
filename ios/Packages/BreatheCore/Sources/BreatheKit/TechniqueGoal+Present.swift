public extension TechniqueGoal {
    /// The goals `techniques` can actually serve, in the fixed calm-first order
    /// of the enum.
    ///
    /// Ordered by the enum rather than by the catalogue so nothing reshuffles
    /// under a person who has learned where sleep sits — and shared rather than
    /// rewritten per screen, because the home screen's aims and the list's
    /// sections reading different orders is a drift nothing but somebody's
    /// memory would catch.
    static func present(in techniques: [Technique]) -> [TechniqueGoal] {
        allCases.filter { goal in
            techniques.contains { $0.goal == goal }
        }
    }

    /// The goal one step forward from this one in `goals`, wrapping past the
    /// end — so every swipe on the home screen changes something, whichever
    /// aim it wakes up on.
    ///
    /// A goal absent from `goals` steps to `goals.first`: the catalogue can
    /// change under a restored `lastGoal`, and starting over from the front is
    /// the same answer `HomeView.settleGoal()` gives. Empty `goals` is the one
    /// case with nothing to offer, and returns nil.
    func next(in goals: [TechniqueGoal]) -> TechniqueGoal? {
        stepped(by: 1, in: goals)
    }

    /// The goal one step back from this one in `goals`, wrapping past the
    /// start. Everything `next(in:)` says about absence and emptiness holds
    /// here too.
    func previous(in goals: [TechniqueGoal]) -> TechniqueGoal? {
        stepped(by: -1, in: goals)
    }
}

private extension TechniqueGoal {
    func stepped(by offset: Int, in goals: [TechniqueGoal]) -> TechniqueGoal? {
        guard !goals.isEmpty else { return nil }
        guard let index = goals.firstIndex(of: self) else { return goals.first }

        let count = goals.count
        return goals[(index + offset + count) % count]
    }
}
