import BreatheKit
import BreatheStyle
import BreatheUI
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
/// one you can already see is how half of people use a wheel. Letter-spaced and
/// lowercase like the tab words below, so the two quiet word treatments read as
/// one system.
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
        .animation(.easeOut(duration: 0.2), value: isExpanded)
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
                        .id(aim)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: spun)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, slot, for: .scrollContent)
        // The same band "begin" sits in under the orb, so the two words stay
        // equidistant from it however the drum is spun.
        .frame(height: 44)
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

        return Button {
            if isChosen {
                isExpanded = true
            } else {
                onSelect(aim)
            }
        } label: {
            word(aim, weight: .regular, tint: Theme.Ink.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(for: aim))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isChosen ? "Shows all the aims" : "Chooses this aim")
    }

    private var fannedOut: some View {
        HStack(spacing: Theme.Spacing.standard) {
            ForEach(goals, id: \.self) { aim in
                fannedWord(aim)
            }
        }
        .frame(height: 44)
        .transition(.opacity)
    }

    private func fannedWord(_ aim: TechniqueGoal) -> some View {
        let isChosen = aim == goal

        return Button {
            onSelect(aim)
            isExpanded = false
        } label: {
            word(
                aim,
                weight: isChosen ? .semibold : .regular,
                tint: isChosen ? aim.accent : Theme.Ink.tertiary
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(for: aim))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// One aim, set the way every aim on this screen is set. The lock rides
    /// beside the word rather than replacing anything, and scales with it so a
    /// larger Dynamic Type setting does not leave a fixed glyph behind.
    private func word(_ aim: TechniqueGoal, weight: Font.Weight, tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.tight) {
            Text(aim.intentObject)
                .font(.system(size: wordSize * typeScale, weight: weight))
                .kerning(1.6 * typeScale)

            if locked.contains(aim) {
                Image(systemName: "lock.fill")
                    .font(.system(size: wordSize * typeScale * 0.72))
            }
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .contentShape(Rectangle())
    }

    /// What VoiceOver reads for an aim. The lock is drawn, so it has to be
    /// spoken too — an image this small carries the whole of why the aim
    /// behaves differently when it is chosen.
    private func label(for aim: TechniqueGoal) -> String {
        locked.contains(aim) ? "\(aim.intentObject), locked" : aim.intentObject
    }

    /// `body`'s size, made a metric so `typeScale` can multiply it without
    /// detaching the word from Dynamic Type. A step up from the `subheadline`
    /// it read at: this word and "begin" are the whole screen, and type sized
    /// to sit quietly beside other content is undersized when there is none.
    @ScaledMetric(relativeTo: .body) private var wordSize: CGFloat = 17
}
