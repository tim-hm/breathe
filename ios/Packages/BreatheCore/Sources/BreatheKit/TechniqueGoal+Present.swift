public extension TechniqueGoal {
    /// The goals `techniques` can actually serve, in the fixed calm-first order
    /// of the enum.
    ///
    /// Ordered by the enum rather than by the catalogue so nothing reshuffles
    /// under a person who has learned where sleep sits — and shared rather than
    /// rewritten per screen, because the wheel's options and the list's sections
    /// reading different orders is a drift nothing but somebody's memory would
    /// catch.
    static func present(in techniques: [Technique]) -> [TechniqueGoal] {
        allCases.filter { goal in
            techniques.contains { $0.goal == goal }
        }
    }
}
