import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The home screen's one word: the aim, faint above the orb, tappable into the
/// full set.
///
/// At rest it shows only what is chosen — the screen's whole vocabulary is one
/// word, the orb, and "begin". Tapping the word fans every aim the catalogue
/// serves into a row, because a hidden gesture (the swipe the caller owns)
/// needs one visible way to learn what it cycles through. Letter-spaced and
/// lowercase like the tab words below, so the two quiet word treatments read
/// as one system.
///
/// Selection is reported, not stored: the caller owns the goal and its
/// persistence, because the swipe that also changes it lives on the caller's
/// container, and two writers to one choice is one too many. The swipe's live
/// travel is handed back in as `drag`, so the word can move under the finger —
/// the one hint the hidden gesture gives that it exists.
struct AimSelector: View {
    /// The aims the catalogue can actually serve, in the order they are shown.
    let goals: [TechniqueGoal]

    /// The chosen aim. Non-optional: the caller only renders this view once
    /// the catalogue has landed and a goal has been settled.
    let goal: TechniqueGoal

    /// How far the screen's width grows the type — 1 on the smallest phones.
    /// Multiplies a Dynamic Type–scaled base, so the person's text setting
    /// still applies on top.
    let typeScale: CGFloat

    /// The horizontal travel of the caller's swipe in flight, zero at rest.
    let drag: CGFloat

    /// Whether the row is fanned out. A binding because dismissal is shared:
    /// selecting collapses it here, tapping anywhere else collapses it from
    /// the caller's tap catcher.
    @Binding var isExpanded: Bool

    let onSelect: (TechniqueGoal) -> Void

    /// Whether the last step moved forward through `goals`. Recorded from the
    /// swipe while it is still in flight — the steps wrap, so goal indices
    /// cannot recover the direction the finger actually travelled — and kept
    /// as state so the push below slides the way the swipe did.
    @State private var forward = true

    /// `body`'s size, made a metric so `typeScale` can multiply it without
    /// detaching the word from Dynamic Type. A step up from the `subheadline`
    /// it read at: this word and "begin" are the whole screen, and type sized
    /// to sit quietly beside other content is undersized when there is none.
    @ScaledMetric(relativeTo: .body) private var wordSize: CGFloat = 17

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isExpanded {
                fannedOut
            } else {
                word
            }
        }
        .animation(.easeOut(duration: 0.2), value: isExpanded)
    }

    /// The resting state: one word, one element. It follows a swipe in flight
    /// and is pushed aside by the aim that replaces it. Adjustable so
    /// VoiceOver keeps the old wheel's gesture — swipe up or down to step
    /// through the aims — alongside the tap that shows them all.
    private var word: some View {
        Button {
            isExpanded = true
        } label: {
            ZStack {
                Text(goal.intentObject)
                    .font(.system(size: wordSize * typeScale))
                    .kerning(1.6 * typeScale)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .id(goal)
                    .transition(push)
            }
            // Travel alone, with no fade under it: this word is `Ink.tertiary`,
            // which sits as close to the AA floor as the palette goes, and
            // `.opacity` is what spends that margin.
            .offset(x: travel)
            .animation(.easeOut(duration: 0.2), value: goal)
            // The frame, and with it the tap target, stays put while the word
            // inside it travels.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .onChange(of: drag) { _, new in
            if new != 0 {
                forward = new < 0
            }
        }
        .accessibilityLabel("I want to")
        .accessibilityValue(goal.intentObject)
        .accessibilityHint("Shows all the aims")
        .accessibilityAdjustableAction { direction in
            let stepped: TechniqueGoal? = switch direction {
            case .increment: goal.next(in: goals)
            case .decrement: goal.previous(in: goals)
            @unknown default: nil
            }
            if let stepped {
                forward = direction == .increment
                onSelect(stepped)
            }
        }
    }

    /// The finger's travel with resistance, capped short of `push`'s throw so
    /// the settle after a commit always moves the way the swipe did.
    private var travel: CGFloat {
        reduceMotion ? 0 : max(-36, min(36, drag * 0.3))
    }

    /// The step's motion: the old word carries on out the way the swipe
    /// travelled while the new one comes in from the far side. Reduce Motion
    /// keeps only the crossfade.
    private var push: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let throwDistance: CGFloat = 56
        return .asymmetric(
            insertion: .offset(x: forward ? throwDistance : -throwDistance)
                .combined(with: .opacity),
            removal: .offset(x: forward ? -throwDistance : throwDistance).combined(with: .opacity)
        )
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

        return Button {
            onSelect(aim)
            isExpanded = false
        } label: {
            Text(aim.intentObject)
                .font(.system(size: wordSize * typeScale, weight: isChosen ? .semibold : .regular))
                .kerning(1.6 * typeScale)
                .foregroundStyle(isChosen ? aim.accent : Theme.Ink.tertiary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
