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

    /// The terminal configuration applied to every session's controller,
    /// via `TerminalController`'s `terminalConfiguration:` parameter.
    ///
    /// Extracted to a static so it can be asserted on directly in tests —
    /// see `TerminalCenterTests`. Two things here are load-bearing and will
    /// silently regress if dropped:
    ///
    /// - `term`: the package bundles no terminfo, so losing this breaks
    ///   ncurses apps (vim, htop, ...) in every spawned shell.
    /// - the four brand colours: dropping them costs the app its visual
    ///   identity, with no error to point at why.
    static let terminalConfiguration = TerminalConfiguration { builder in
        // The package bundles no terminfo; without this the default
        // TERM=xterm-ghostty breaks ncurses apps (vim, htop, ...) in the
        // spawned shell.
        builder.withCustom("term", "xterm-256color")

        // Terminal-content breathing room. Done via ghostty config
        // rather than AppKit view nesting/insets around TerminalView,
        // since ghostty already renders its own content padding.
        builder.withCustom("window-padding-x", "10")
        builder.withCustom("window-padding-y", "10")

        // Brand the cursor and selection only. `background`/`foreground`
        // are deliberately left unset here — those belong to whatever
        // shell theme the user has configured, and only the cursor and
        // selection are ours to brand.
        builder.withCursorColor(Theme.Terminal.cursorColor)
        builder.withCursorText(Theme.Terminal.cursorText)
        builder.withSelectionBackground(Theme.Terminal.selectionBackground)
        builder.withSelectionForeground(Theme.Terminal.selectionForeground)
    }

    /// Invoked with the session id after the underlying shell process exits
    /// and the terminal has already been torn down.
    var onProcessExit: ((String) -> Void)?

    /// Invoked with the session id and parsed activity whenever a session's
    /// terminal reports (or clears) a status via
    /// `SessionDelegateProxy.terminalDidRequestDesktopNotification`. A nil
    /// activity means "clear."
    var onSessionActivity: ((String, SessionActivity?) -> Void)?

    /// Invoked with the session id and new title whenever a session's
    /// terminal reports an OSC window-title change via
    /// `SessionDelegateProxy.terminalDidChangeTitle`.
    var onTitleChange: ((String, String) -> Void)?

    /// Lazily creates (on first call) or returns the cached `TerminalView`
    /// for a session, spawning the user's login shell rooted at
    /// `workingDirectory`.
    func terminalView(for sessionID: String, workingDirectory: String) -> TerminalView {
        if let entry = entries[sessionID] {
            return entry.view
        }

        let proxy = SessionDelegateProxy(sessionID: sessionID, center: self)
        // DropTerminalView adds Finder drag-and-drop (the package itself has
        // none) — see its doc comment for why. The stored type stays
        // `TerminalView`; every caller only needs the base API.
        let view = DropTerminalView(frame: .zero)

        // Setup order mirrors the package's own AppKit example: delegate,
        // then configuration, then controller, before the caller adds the
        // view to the hierarchy.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory
        )
        // configSource/theme are left at their defaults (`.none`/`.default`)
        // deliberately — see the doc comment on `terminalConfiguration`
        // above for why that, plus this parameter, exactly reproduces what
        // the closure-taking convenience initializer used to do.
        let controller = TerminalController(terminalConfiguration: Self.terminalConfiguration)
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

    /// Called by a session's delegate proxy when it parses a recognised
    /// `agents:status` notification off the tty. Just forwards — no
    /// terminal-lifecycle teardown needed here, unlike `handleProcessExit`.
    func handleSessionActivity(sessionID: String, activity: SessionActivity?) {
        onSessionActivity?(sessionID, activity)
    }

    /// Called by a session's delegate proxy when the shell reports a new OSC
    /// window title. Just forwards — same reasoning as `handleSessionActivity`.
    func handleTitleChange(sessionID: String, title: String) {
        onTitleChange?(sessionID, title)
    }
}

/// Small per-session delegate that closes over a session id and forwards to
/// `TerminalCenter`. Each session needs its own instance since neither
/// delegate callback carries the sender's identity. `TerminalView.delegate`
/// is weak, so `TerminalCenter` retains this object itself (alongside the
/// view/controller in its cache entry).
@MainActor
final class SessionDelegateProxy: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate, TerminalSurfaceDesktopNotificationDelegate {
    let sessionID: String
    weak var center: TerminalCenter?

    init(sessionID: String, center: TerminalCenter) {
        self.sessionID = sessionID
        self.center = center
    }

    func terminalDidChangeTitle(_ title: String) {
        // The agent's OSC title becomes the session's display name (sidebar
        // + window title) unless the user has manually renamed it, and also
        // the window subtitle — see SessionRow.displayName/subtitle and
        // AppStore.setSessionTitle, which persists it onto the row.
        center?.handleTitleChange(sessionID: sessionID, title: title)
    }

    func terminalDidClose(processAlive: Bool) {
        center?.handleProcessExit(sessionID: sessionID)
    }

    /// The package dispatches every specialized delegate by conditional-
    /// casting the single `view.delegate` object (see
    /// `TerminalCallbackBridge.handleAction`), so this conformance alone is
    /// all the registration this proxy needs — nothing else has to opt it
    /// in.
    ///
    /// A nil parse result means a genuine desktop notification from some
    /// other program running in the shell (e.g. an npm build finishing) —
    /// the app doesn't surface those at all today, so ignoring it here is
    /// correct for now, not a silent drop of something we should have
    /// handled.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        guard let message = SessionActivity.parseStatusMessage(title: title, body: body) else {
            return
        }
        switch message {
        case .set(let activity):
            center?.handleSessionActivity(sessionID: sessionID, activity: activity)
        case .clear:
            center?.handleSessionActivity(sessionID: sessionID, activity: nil)
        }
    }
}
