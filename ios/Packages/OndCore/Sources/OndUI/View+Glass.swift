#if os(iOS)
    import SwiftUI

    public extension View {
        /// A raised surface, drawn on glass.
        ///
        /// The counterpart to `paletteGround()`: that one grounds a screen, this
        /// one lifts a card off it. Both live here rather than beside the views
        /// that call them, because a card recipe copied into each feature is how a
        /// second visual vocabulary starts.
        ///
        /// Glass rather than the flat `Surface.raised` fill and hairline it
        /// replaces, for a reason beyond the material being the platform's: a
        /// selected state becomes one property instead of a fill and a stroke that
        /// have to be kept agreeing.
        ///
        /// - Parameters:
        ///   - accent: The colour to tint the glass with, or nil to leave it
        ///     untinted. Selection is the tint's presence rather than a change in
        ///     its strength, so a card has one value to pass and no second state to
        ///     get wrong.
        ///   - interactive: Whether the glass should answer a press with the
        ///     material's own flex and highlight. True where the card is itself a
        ///     button — a `plain`-styled button over a flat fill has nothing that
        ///     moves under a finger — and false where it merely holds a control,
        ///     which would otherwise flex when the control inside it was the thing
        ///     being touched.
        func glassCard(tinted accent: Color? = nil, interactive: Bool = false) -> some View {
            var glass = Glass.regular

            if let accent {
                glass = glass.tint(accent.opacity(Theme.Glass.selection))
            }

            if interactive {
                glass = glass.interactive()
            }

            return glassEffect(glass, in: .rect(cornerRadius: Theme.Radius.card))
        }
    }
#endif
