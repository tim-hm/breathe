import SwiftUI

public extension View {
    /// Puts the palette's ground behind a scrolling screen, in place of the
    /// system's.
    ///
    /// A `List` or `ScrollView` paints its own background — white in the light
    /// appearance, pure black in the dark one. Pure black is not this palette's
    /// ground, and a screen that keeps it reads as a different app from the one
    /// the session player draws. Hiding the scroll background and putting
    /// `Theme.Surface.ground` under it is what makes them agree.
    ///
    /// A `List` needs one thing more: its rows stay opaque once the scroll
    /// background is hidden, and `listRowBackground` only reaches a row from
    /// inside the list, so the row itself carries `.listRowBackground(.clear)`.
    func paletteGround() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.Surface.ground)
    }
}
