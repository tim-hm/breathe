import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The home screen's one word: the aim, faint above the orb, spun on a drum and
/// tappable into the full set.
///
/// A drum rather than the bare word it replaced, because a hidden gesture has
/// no affordance: the neighbouring aims sitting turned away at either side are
/// what say the row can be spun, and they say it without a hint, an arrow, or a
/// first-run tip. Horizontal rather than the stock `Picker`'s vertical, which is
/// the one thing that wheel could not be — the aim reads left to right with the
/// screen, and a vertical drum here would spin across the orb's axis rather than
/// with it.
///
/// Tapping the centred word fans every aim the catalogue serves into a row;
/// tapping a neighbour spins to it instead, because reaching straight for the
/// one you can already see is how half of people use a wheel. Lowercase and
/// letter-spaced, which is the treatment the tab words take too, so the screen's
/// two quiet word rows read as one system — the tracking here grows with the
/// type rather than being pinned to theirs, because letter-spacing that stays
/// put while the letters grow closes up.
///
/// Selection is reported, not stored: the caller owns the goal and its
/// persistence, and two writers to one choice is one too many.
struct AimSelector: View {
    /// The aims the catalogue can actually serve, in the order they are shown.
    let goals: [TechniqueGoal]

    /// The chosen aim. Non-optional: the caller only renders this view once
    /// the catalogue has landed and a goal has been settled.
    let goal: TechniqueGoal

    /// The aims whose exercise this person's tier does not open. Marked with a
    /// lock rather than hidden or disabled: an aim you cannot reach yet is
    /// still worth knowing the app has, and spinning onto it is how somebody
    /// finds out what a subscription is for.
    let locked: Set<TechniqueGoal>

    /// How far the screen's width grows the type — 1 on the smallest phones.
    /// Multiplies a Dynamic Type–scaled base, so the person's text setting
    /// still applies on top.
    let typeScale: CGFloat

    /// The width the drum spins in. Passed rather than measured here: the
    /// caller already reads the screen's geometry for `typeScale`, and a second
    /// `GeometryReader` inside a row this small is a layout pass for a number
    /// somebody already has.
    let width: CGFloat

    /// Whether the row is fanned out. A binding because dismissal is shared:
    /// selecting collapses it here, tapping anywhere else collapses it from
    /// the caller's tap catcher.
    @Binding var isExpanded: Bool

    let onSelect: (TechniqueGoal) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One aim's share of the drum. Three across: the chosen one and the aim
    /// waiting at either side, which is the least that still reads as a wheel.
    private var slot: CGFloat {
        width / 3
    }

    var body: some View {
        Group {
            if isExpanded {
                fannedOut
            } else {
                drum
            }
        }
        // The band "begin" also sits in under the orb, which is what keeps the
        // two words equidistant from it whatever either line height is. Scaled
        // rather than a flat 44 so an accessibility text size grows the band
        // instead of clipping inside it.
        .frame(height: band)
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        // Restores what the wheel this replaced offered: step through the aims
        // without having to land on each neighbour and double-tap it. The drum
        // scrolls to whatever the caller sets, so the two agree by themselves.
        .accessibilityAdjustableAction { direction in
            let stepped: TechniqueGoal? = switch direction {
            case .increment: goal.next(in: goals)
            case .decrement: goal.previous(in: goals)
            @unknown default: nil
            }
            if let stepped {
                onSelect(stepped)
            }
        }
    }

    /// The resting state: the chosen aim centred, its neighbours turned away at
    /// either side.
    ///
    /// A snapping scroll view rather than a gesture and an offset, so the spin
    /// carries the momentum, the rubber-banding at either end, and the
    /// scroll-to-item that VoiceOver and Full Keyboard Access already know how
    /// to drive. The margins are one slot wide so the first and last aims can
    /// reach the middle; without them the drum would stop with `calm` still a
    /// third of the way left.
    private var drum: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(goals, id: \.self) { aim in
                    aimWord(aim)
                        .frame(width: slot)
                        .scrollTransition(
                            reduceMotion ? .identity : .interactive,
                            axis: .horizontal
                        ) { face, phase in
                            face
                                .rotation3DEffect(
                                    .degrees(phase.value * 60),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.6
                                )
                                .scaleEffect(1 - abs(phase.value) * 0.18)
                                // Enough to read as turned away, not enough to
                                // stop reading: a neighbour nobody can make out
                                // is the bare word this drum replaced. The
                                // centred aim sits at phase zero and keeps the
                                // ink's measured contrast untouched.
                                .opacity(1 - abs(phase.value) * 0.45)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: spun)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, slot, for: .scrollContent)
        .transition(.opacity)
    }

    /// The drum's position, as the aim at its centre.
    ///
    /// Writing straight through to `onSelect` is what makes the spin tick: the
    /// caller's haptic fires on each aim the drum passes, the way a wheel
    /// clicks past its detents rather than only where it lands.
    private var spun: Binding<TechniqueGoal?> {
        Binding(
            get: { goal },
            set: { spun in
                guard let spun, spun != goal else { return }
                onSelect(spun)
            }
        )
    }

    /// One aim on the drum. Tapping the centred one fans the set out; tapping a
    /// neighbour spins to it.
    private func aimWord(_ aim: TechniqueGoal) -> some View {
        let isChosen = aim == goal

        return button(
            aim,
            weight: .regular,
            tint: Theme.Ink.tertiary,
            hint: isChosen ? "Shows all the aims" : "Chooses this aim"
        ) {
            if isChosen {
                isExpanded = true
            } else {
                onSelect(aim)
            }
        }
    }

    private var fannedOut: some View {
        HStack(spacing: Theme.Spacing.standard) {
            ForEach(goals, id: \.self) { aim in
                fannedWord(aim)
            }
        }
        .transition(.opacity)
    }

    private func fannedWord(_ aim: TechniqueGoal) -> some View {
        let isChosen = aim == goal

        return button(
            aim,
            weight: isChosen ? .semibold : .regular,
            tint: isChosen ? aim.accent : Theme.Ink.tertiary,
            hint: nil
        ) {
            onSelect(aim)
            isExpanded = false
        }
    }

    /// One aim as a control, set the way every aim on this screen is set.
    ///
    /// Both rows come through here so their accessibility cannot drift apart:
    /// the label, the selected trait, and the lock's spoken name are written
    /// once, and only the action and the emphasis differ between them.
    private func button(
        _ aim: TechniqueGoal,
        weight: Font.Weight,
        tint: Color,
        hint: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.tight) {
                Text(aim.intentObject)
                    .font(.system(size: wordSize * typeScale, weight: weight))
                    .kerning(1.6 * typeScale)
                    .foregroundStyle(tint)

                if locked.contains(aim) {
                    // The brand accent and the wording the catalogue's lock
                    // already uses, so one glyph does not mean two things in
                    // two places. Sized off the word so a larger Dynamic Type
                    // setting does not leave a fixed glyph behind.
                    Image(systemName: "lock.fill")
                        .font(.system(size: wordSize * typeScale * 0.72))
                        .foregroundStyle(Theme.Accent.brand)
                        .accessibilityHidden(true)
                }
            }
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(for: aim))
        .accessibilityAddTraits(aim == goal ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(hint ?? "")
    }

    /// What VoiceOver reads for an aim. The lock is drawn, so it has to be
    /// spoken too, in the catalogue's words rather than new ones: "locked"
    /// names a punishment, and this glyph is the app offering something.
    private func label(for aim: TechniqueGoal) -> String {
        locked.contains(aim)
            ? "\(aim.intentObject), included with önd Plus"
            : aim.intentObject
    }

    /// `body`'s size, made a metric so `typeScale` can multiply it without
    /// detaching the word from Dynamic Type. A step up from the `subheadline`
    /// it read at: this word and "begin" are the whole screen, and type sized
    /// to sit quietly beside other content is undersized when there is none.
    @ScaledMetric(relativeTo: .body) private var wordSize: CGFloat = 17

    /// The row's height: a comfortable touch target at the default text size,
    /// and taller than one as the text grows.
    @ScaledMetric(relativeTo: .body) private var band: CGFloat = 44
}
