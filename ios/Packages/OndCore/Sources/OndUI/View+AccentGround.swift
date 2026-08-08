import SwiftUI

public extension View {
    /// Grounds a screen in an accent, strongest at the top and fading down it.
    ///
    /// The counterpart to `paletteGround()`, for the screens that wear a
    /// technique's colour rather than the palette's neutral one. The wash goes
    /// over `Theme.Surface.ground` rather than over whatever the presentation
    /// put behind it — a translucent gradient alone would sit on the system's
    /// background, which is pure black at night and paper white by day, and
    /// neither is this palette.
    ///
    /// **Only `Theme.Ink.primary` is legible on it.** The wash drags the ground
    /// towards mid-luminance from whichever end it started, which is precisely
    /// where the quieter inks live: at `Theme.Wash.strongest` they measure
    /// 3.26:1 and 2.40:1, and an accent used as its own text colour falls to
    /// 2.93:1. Normal-size text on this ground therefore carries no
    /// `foregroundStyle` of its own and inherits primary — hierarchy here is
    /// size and weight, because tone is spent on being readable at all.
    ///
    /// Not set as a `foregroundStyle` here, deliberately: the failure this
    /// replaced was explicit `Theme.Ink.secondary` overrides, which beat any
    /// default this could install, so a default would buy nothing and hide
    /// where the ink is decided.
    ///
    /// - Parameter accent: The colour to wash the ground in — a goal's accent
    ///   on the session player. Taken as a `Color` rather than reached for,
    ///   because this module knows nothing about techniques or goals.
    func accentGround(_ accent: Color) -> some View {
        // Expanded first: a screen whose content does not fill the display —
        // the three-second countdown is a small centred stack — would otherwise
        // get a ground the size of that stack and the system's background
        // around it.
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Theme.Surface.ground
                    .overlay(
                        LinearGradient(
                            colors: [
                                accent.opacity(Theme.Wash.strongest),
                                accent.opacity(Theme.Wash.faintest),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .ignoresSafeArea()
            )
    }
}
