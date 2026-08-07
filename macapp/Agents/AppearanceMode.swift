import AppKit
import SwiftUI

/// The app's appearance preference: follow the system, or force light/dark.
///
/// The raw values are a persistence contract — they're what `@AppStorage`
/// writes to `UserDefaults` under `defaultsKey`. Renaming a case changes its
/// raw value too unless given an explicit string, which would silently reset
/// existing users' saved preference back to `.system` (the decode falls
/// through to the declared default rather than failing loudly). Don't rename
/// cases; add new ones if the set of choices grows.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// Shared by `AgentsApp` and `SettingsView` so both bind to the same
    /// `UserDefaults` entry via `@AppStorage`.
    static let defaultsKey = "appearanceMode"

    var id: Self { self }

    /// Display name for the Settings picker's menu.
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The `NSAppearance` that expresses this preference. `.system` maps to
    /// `nil` — see `apply()` for what that means to AppKit.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this preference to the running app by setting
    /// `NSApp.appearance`. Assigning `nil` is what "follow system" means to
    /// AppKit: rather than a sentinel this code has to interpret, `nil` makes
    /// the app re-inherit the system appearance directly and track
    /// subsequent system-level changes automatically, with no observer of
    /// our own needed.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
