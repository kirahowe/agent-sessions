import AppKit

/// The single point through which every keyboard shortcut in the app
/// flows: one local `NSEvent` monitor. Menus render their shortcuts from
/// the same `Keymap.standard` table (via `Shortcut.swiftUIShortcut`), but
/// this monitor is what actually consumes a matched keydown — by
/// returning nil once `perform` reports the action as handled, the system
/// never also dispatches the menu item's own key equivalent, so a binding
/// can never fire twice. Adding a shortcut = adding a Keymap entry; the
/// uniqueness test in KeymapTests guards against accidental conflicts.
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
            return nil // consumed: handled, so the system's own menu key-equivalent never also fires
        }
        return event // action not currently valid (e.g. ⌘W with nothing selected) — let the system handle/beep normally
    }
}
