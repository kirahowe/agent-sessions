import AppKit
import SwiftUI

/// Every user-invocable action in the app, expressed as data rather than a
/// scattered set of ad hoc handlers. `Keymap.standard` is the single source
/// of truth mapping these to physical key combinations; `ShortcutRouter`
/// and the app's menus both dispatch through `AppActions.perform(_:)`.
enum AppAction: Hashable {
    case newSession
    case closeSession
    case renameSession
    case closeWindow
    case addProject
    case removeProject
    case previousSession
    case nextSession
    case selectSession(Int)
    case newWorkspace
    case closeWorkspace
    case showShortcutHelp
}

extension AppAction: CaseIterable {
    /// `selectSession` carries an associated value, so Swift can't
    /// synthesize `CaseIterable` automatically — enumerate all 9 index
    /// cases (0...8, for the ⌘1–⌘9 bindings) explicitly alongside the
    /// simple cases.
    static var allCases: [AppAction] {
        [
            .newSession, .closeSession, .renameSession, .closeWindow, .addProject, .removeProject,
            .previousSession, .nextSession, .newWorkspace, .closeWorkspace, .showShortcutHelp,
        ]
            + (0..<9).map { AppAction.selectSession($0) }
    }
}

extension AppAction {
    /// Human-facing label for the ⌘? shortcut-help sheet, which is
    /// GENERATED from this + `Keymap.standard` rather than hand-maintained
    /// (see ShortcutHelpView). `selectSession`'s nine cases deliberately all
    /// share this same title, which is how they collapse into one display
    /// row (see ShortcutHelpView.rows(in:)).
    var helpTitle: String {
        switch self {
        case .newSession: return "New Session"
        case .closeSession: return "Close Session"
        case .renameSession: return "Rename Session…"
        case .closeWindow: return "Close Window"
        case .addProject: return "Add Project…"
        case .removeProject: return "Remove Project…"
        case .previousSession: return "Previous Session"
        case .nextSession: return "Next Session"
        case .selectSession: return "Jump to session"
        case .newWorkspace: return "New Workspace"
        case .closeWorkspace: return "Close Workspace…"
        case .showShortcutHelp: return "Keyboard Shortcuts"
        }
    }

    /// Which section of the shortcut-help sheet this action's row renders
    /// under. Sheet section order is fixed in `ShortcutHelpView`.
    var helpGroup: String {
        switch self {
        case .newSession, .closeSession, .renameSession, .previousSession, .nextSession, .selectSession:
            return "Sessions"
        case .newWorkspace, .closeWorkspace:
            return "Workspaces"
        case .addProject, .removeProject:
            return "Projects"
        case .closeWindow:
            return "Window"
        case .showShortcutHelp:
            return "Help"
        }
    }
}

/// A physical key combination: a key plus an exact set of modifier flags.
struct Shortcut: Hashable {
    enum Key: Hashable {
        case char(Character)
        case upArrow
        case downArrow
    }

    let key: Key
    let modifiers: NSEvent.ModifierFlags

    /// The only modifier bits Shortcut ever cares about. Matching always
    /// intersects against this set first so incidental flags (caps lock,
    /// numeric pad, function, ...) never break a match.
    private static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    // NSEvent.ModifierFlags does not conform to Hashable, so Shortcut can't
    // derive Hashable automatically — implement it by hand over the
    // rawValue of the intersected (relevant-only) flags.
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.intersection(Self.relevantModifiers).rawValue)
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.key == rhs.key
            && lhs.modifiers.intersection(relevantModifiers) == rhs.modifiers.intersection(relevantModifiers)
    }

    /// Whether `event` exactly matches this shortcut: modifier flags must
    /// match EXACTLY over [.command, .shift, .option, .control] (so ⌘W
    /// never matches ⇧⌘W and vice versa), and the key must match.
    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(Self.relevantModifiers) == modifiers.intersection(Self.relevantModifiers) else {
            return false
        }
        switch key {
        case .char(let character):
            guard let characters = event.charactersIgnoringModifiers else { return false }
            return characters.lowercased() == String(character).lowercased()
        case .upArrow:
            return event.specialKey == .upArrow
        case .downArrow:
            return event.specialKey == .downArrow
        }
    }

    /// For SwiftUI menu display only — actual matching/consuming always
    /// goes through `matches(_:)` via `ShortcutRouter`.
    var swiftUIShortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
        let keyEquivalent: KeyEquivalent
        switch key {
        case .char(let character): keyEquivalent = KeyEquivalent(character)
        case .upArrow: keyEquivalent = .upArrow
        case .downArrow: keyEquivalent = .downArrow
        }

        var eventModifiers: EventModifiers = []
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }

        return (keyEquivalent, eventModifiers)
    }

    /// Human-facing rendering for the shortcut-help sheet, e.g. "⌘T",
    /// "⇧⌘W", "⌥⌘↓", "⌘1". Glyph order follows the conventional ⌃⌥⇧⌘
    /// (control, option, shift, command) ordering.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        switch key {
        case .char(let character): result += String(character).uppercased()
        case .upArrow: result += "↑"
        case .downArrow: result += "↓"
        }
        return result
    }
}

/// THE single source of truth for every keyboard shortcut in the app.
/// `ShortcutRouter` consumes matched keydowns; menu items render shortcuts
/// from this same table via `Shortcut.swiftUIShortcut`. To add a shortcut,
/// add an entry here — `KeymapTests` guards against accidental conflicts.
enum Keymap {
    static let standard: [AppAction: Shortcut] = {
        var map: [AppAction: Shortcut] = [
            .newSession: Shortcut(key: .char("t"), modifiers: [.command]),
            .closeSession: Shortcut(key: .char("w"), modifiers: [.command]),
            // ⇧⌘R, not plain ⌘R: ShortcutRouter intercepts every ⌘ event
            // globally before the hosted ghostty terminal sees it, so
            // binding plain ⌘R would permanently steal it from the terminal.
            .renameSession: Shortcut(key: .char("r"), modifiers: [.command, .shift]),
            .closeWindow: Shortcut(key: .char("w"), modifiers: [.command, .shift]),
            .addProject: Shortcut(key: .char("n"), modifiers: [.command, .shift]),
            .previousSession: Shortcut(key: .upArrow, modifiers: [.command, .option]),
            .nextSession: Shortcut(key: .downArrow, modifiers: [.command, .option]),
            .newWorkspace: Shortcut(key: .char("n"), modifiers: [.command]),
            .showShortcutHelp: Shortcut(key: .char("?"), modifiers: [.command, .shift]),
            // .removeProject and .closeWorkspace intentionally have no entry: menu-only.
        ]
        for index in 0..<9 {
            let digit = Character("\(index + 1)")
            map[.selectSession(index)] = Shortcut(key: .char(digit), modifiers: [.command])
        }
        return map
    }()

    /// Linear match over `standard`. O(n) is fine for ~16 entries checked
    /// once per keydown.
    static func action(for event: NSEvent) -> AppAction? {
        standard.first { _, shortcut in shortcut.matches(event) }?.key
    }
}
