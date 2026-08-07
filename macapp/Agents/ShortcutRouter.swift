import AppKit

/// The first point through which every keyboard shortcut in the app
/// flows: one local `NSEvent` monitor. Menus render their shortcuts from
/// the same `Keymap.standard` table (via `Shortcut.swiftUIShortcut`), and
/// this monitor returns nil for a matched, handled keydown — but that does
/// *not* stop the system from also dispatching the menu item's own key
/// equivalent. Measured against the running app, both fire, so a single
/// keystroke reaches `AppActions.perform` twice; `AppActions` is what
/// makes the second call a no-op, deduplicating by the originating
/// keydown. Adding a shortcut = adding a Keymap entry; the uniqueness test
/// in KeymapTests guards against accidental conflicts.
/// Actions that present modal dialogs defer that presentation via
/// `AppActions.present` rather than presenting inline: a modal event loop
/// must never run inside this monitor callback, because the triggering
/// keydown is still suspended in AppKit's dispatch, and that dispatch
/// resumes corrupted once the callback finally returns (shortcut keys
/// leaking into the terminal after the dialog closes). Deferral is also
/// what keeps `AppActions`' dedup sound — with no modal loop running
/// between the two dispatches, both see the same `NSApp.currentEvent`.
@MainActor
final class ShortcutRouter {
    private var monitor: Any?
    private let perform: (AppAction) -> Bool
    private let isModalActive: () -> Bool

    init(perform: @escaping (AppAction) -> Bool, isModalActive: @escaping () -> Bool = { NSApp.modalWindow != nil }) {
        self.perform = perform
        self.isModalActive = isModalActive
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // Internal (not private) so AgentsTests can exercise the consume/pass-
    // through decision directly via @testable import, without needing a
    // real global NSEvent monitor or real NSApp modal state.
    func handle(_ event: NSEvent) -> NSEvent? {
        // Alerts/open panels own the keyboard while modal.
        if isModalActive() {
            return event
        }
        // Cheap fast-path: every shortcut in Keymap is ⌘-based, so plain
        // typing never pays the matching cost.
        guard event.modifierFlags.contains(.command) else {
            return event
        }
        guard let action = Keymap.action(for: event) else {
            return event
        }
        if perform(action) {
            return nil // handled — swallow it here (the menu key-equivalent still fires; AppActions dedups that)
        }
        return event // action not currently valid (e.g. ⌘W with nothing selected) — let the system handle/beep normally
    }
}
