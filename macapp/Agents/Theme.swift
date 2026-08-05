import SwiftUI

/// The app's brand palette, gathered in one place rather than scattered as
/// literal hex strings at each call site. These values are shared with the
/// app icon — `design/icon/README.md` is the source of truth for the palette
/// as a whole (including the contrast-ratio reasoning behind why the accent
/// and the icon's bright mark colour aren't the same value); this file just
/// wires the numbers into the Swift/AppKit/ghostty call sites that need them.
enum Theme {
    /// The app's tint, resolved from the `AccentColor` asset catalog entry
    /// (`Assets.xcassets/AccentColor.colorset`) rather than computed inline,
    /// so light/dark switching is handled by the asset catalog's two
    /// variants instead of an `if colorScheme` branch here.
    ///
    /// Deliberately NOT `Color.accentColor`. That property resolves to
    /// whatever tint is *currently in effect* — when the user has picked a
    /// system accent colour in System Settings, that's the system's colour,
    /// not ours. Tinting with `Color.accentColor` would therefore be an
    /// identity operation that silently does nothing in exactly the case
    /// it's meant to override. Naming the asset directly, as done here,
    /// always resolves to our colour regardless of the system setting. This
    /// is exactly the kind of thing a future "simplification" could
    /// reintroduce, so don't collapse it back to `.accentColor`.
    static let accent = Color("AccentColor", bundle: .main)

    /// Terminal-only brand colours, expressed as the hex-string values
    /// `TerminalConfiguration.Builder`'s typed `with*` methods take (see
    /// their use in `TerminalCenter`). Only the cursor and selection are
    /// branded — `background`/`foreground` are deliberately left alone so
    /// the user's own shell theme controls them.
    enum Terminal {
        static let cursorColor = "#64D1DD"
        static let cursorText = "#06222A"
        static let selectionBackground = "#14515E"
        static let selectionForeground = "#EDF3F4"
    }
}
