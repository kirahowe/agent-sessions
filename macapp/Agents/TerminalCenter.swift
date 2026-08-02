import AppKit
import GhosttyTerminal

/// Owns the lifecycle of every live `TerminalView`/`TerminalController` pair,
/// one per session. Scoped strictly to terminal lifecycle (create/get/close);
/// NSView container/subview/constraint/visibility/focus mechanics live in
/// `TerminalHostView`.
@MainActor
final class TerminalCenter: SessionTerminating {
    private struct Entry {
        let view: TerminalView
        let controller: TerminalController
        let delegateProxy: SessionDelegateProxy
    }

    private var entries: [String: Entry] = [:]

    /// Invoked with the session id after the underlying shell process exits
    /// and the terminal has already been torn down.
    var onProcessExit: ((String) -> Void)?

    /// Lazily creates (on first call) or returns the cached `TerminalView`
    /// for a session, spawning the user's login shell rooted at
    /// `workingDirectory`.
    func terminalView(for sessionID: String, workingDirectory: String) -> TerminalView {
        if let entry = entries[sessionID] {
            return entry.view
        }

        let proxy = SessionDelegateProxy(sessionID: sessionID, center: self)
        let view = TerminalView(frame: .zero)

        // Setup order mirrors the package's own AppKit example: delegate,
        // then configuration, then controller, before the caller adds the
        // view to the hierarchy.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory
        )
        let controller = TerminalController { builder in
            // The package bundles no terminfo; without this the default
            // TERM=xterm-ghostty breaks ncurses apps (vim, htop, ...) in the
            // spawned shell.
            builder.withCustom("term", "xterm-256color")
        }
        view.controller = controller

        entries[sessionID] = Entry(view: view, controller: controller, delegateProxy: proxy)
        return view
    }

    /// Tears down a session's terminal: removes the view from its superview
    /// and drops every strong reference we hold (view, controller, delegate
    /// proxy) so ARC's deinit chain runs the actual ghostty teardown. No-op
    /// if the id isn't cached.
    func closeSession(_ sessionID: String) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        entry.view.removeFromSuperview()
    }

    /// Called by a session's delegate proxy when its shell process exits.
    /// Tears down the terminal first, then notifies the callback regardless
    /// of what the caller does with the notification.
    func handleProcessExit(sessionID: String) {
        closeSession(sessionID)
        onProcessExit?(sessionID)
    }
}

/// Small per-session delegate that closes over a session id and forwards to
/// `TerminalCenter`. Each session needs its own instance since neither
/// delegate callback carries the sender's identity. `TerminalView.delegate`
/// is weak, so `TerminalCenter` retains this object itself (alongside the
/// view/controller in its cache entry).
@MainActor
final class SessionDelegateProxy: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    let sessionID: String
    weak var center: TerminalCenter?

    init(sessionID: String, center: TerminalCenter) {
        self.sessionID = sessionID
        self.center = center
    }

    func terminalDidChangeTitle(_ title: String) {
        // No-op for day 0 — window title is driven by session/project name,
        // not the shell's OSC title.
    }

    func terminalDidClose(processAlive: Bool) {
        center?.handleProcessExit(sessionID: sessionID)
    }
}
