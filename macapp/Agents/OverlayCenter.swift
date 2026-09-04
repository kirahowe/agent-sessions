import AppKit
import Combine
import GhosttyTerminal

/// Owns the full-pane *review overlays*: transient surfaces that cover the
/// whole detail pane, run exactly one command each, and vanish when that
/// command exits.
///
/// This exists for terminal review tools — revdiff, driven by the Claude Code
/// plugin's launcher override — that are themselves full-screen TUIs. The
/// agent asking for the review is already running inside a session terminal
/// and already owns that tty with its own full-screen UI, so a TUI it spawns
/// has nowhere to draw. Every other terminal revdiff supports answers this
/// with a split pane or a popup window; this app answers it by taking the
/// pane over — but only for the session that asked. Each overlay is keyed by
/// its invoking session: it is shown only while that session is selected,
/// stays alive (hidden, still running) while another session is on screen,
/// and comes back exactly where it was on reselection. The session
/// underneath keeps running throughout and returns untouched on exit.
///
/// Deliberately NOT modelled as sessions: overlays are never persisted,
/// never appear in the sidebar as rows, and never survive a relaunch.
/// `TerminalCenter` is keyed by session id and coupled to `AppStore`'s
/// persisted rows; an overlay borrows a session's identity but must never be
/// saved, so a separate owner keeps that impossible by construction.
///
/// One overlay per session, by construction. A session's pane can only show
/// one review, and a queue would mean a review silently waiting behind
/// another with no UI to explain the delay — so a second request from the
/// same session is refused and the caller reports that rather than blocking.
/// Different sessions review concurrently without contention.
@MainActor
final class OverlayCenter: ObservableObject {
    /// Why a command string rather than a `TerminalSurfaceOptions` command:
    /// libghostty's exec backend spawns the user's login shell and offers no
    /// argv override (see `TerminalSessionBackend` — it is `.exec` or an
    /// in-memory session, nothing more). Handing the command to that shell as
    /// typed input is the same mechanism the restore banner already uses, so
    /// it is a path this app is known to work on rather than a new one.
    private struct Active {
        let sessionID: String
        let view: TerminalView
        let command: String
        let delegateProxy: OverlayDelegateProxy
        /// Set once `TerminalHostView` has mounted the surface and asked for
        /// delivery. From then on the command is typed as soon as the
        /// surface exists — see `surfaceAttached`.
        var deliveryScheduled = false
        var didDeliver = false
        /// Whether libghostty has built this overlay's surface. `sendText`
        /// is a silent no-op until it has — and the surface is created only
        /// once the view is in a window with a real size, an arbitrary
        /// number of run-loop turns after the view is mounted. Typing before
        /// then loses the command outright, which left the user staring at a
        /// bare login shell where the review should have been.
        var surfaceAttached = false
    }

    enum PresentError: Error, Equatable {
        case alreadyActive
    }

    /// How a review ended, forwarded to `onClosed` so the control server can
    /// answer the launcher truthfully: `finished` means the review command
    /// exited on its own, `cancelled` means the app tore it down (its session
    /// was closed or quiesced) and the launcher must be unblocked with a
    /// failure rather than a fabricated success.
    enum ReviewOutcome {
        case finished
        case cancelled
    }

    /// The sessions with a live review, published so `TerminalHostView`
    /// re-renders on present/dismiss and the sidebar can flag a review
    /// waiting in an unselected session. The `Active` records stay private:
    /// observers only need to know *that* the overlay set changed.
    @Published private(set) var reviewSessionIDs: Set<String> = []

    private var active: [String: Active] = [:]

    private let textDelivery: @MainActor (TerminalView, String) -> Void

    init(
        textDelivery: @escaping @MainActor (TerminalView, String) -> Void = { view, text in
            view.sendText(text)
        }
    ) {
        self.textDelivery = textDelivery
    }

    /// Invoked with the invoking session id after an overlay's surface has
    /// been torn down, with how it ended. The control server uses this to
    /// answer the launcher blocked on that session's review.
    var onClosed: ((String, ReviewOutcome) -> Void)?

    /// The overlay view belonging to `sessionID`, if that session has a live
    /// review.
    func view(forSession sessionID: String) -> TerminalView? {
        active[sessionID]?.view
    }

    /// Every live overlay view. `TerminalHostView` mounts all of them — not
    /// just the selected session's — because a review can be requested by a
    /// session that isn't on screen, and its surface must exist (view in the
    /// hierarchy) before the command can be delivered and start running.
    var allViews: [TerminalView] {
        active.values.map(\.view)
    }

    /// Creates an overlay surface for `sessionID`'s review. The command is
    /// not sent here — the surface has to be in the view hierarchy first, so
    /// delivery waits for `deliverCommandsIfNeeded()`; see that method for why.
    func present(command: String, workingDirectory: String, sessionID: String) throws {
        guard active[sessionID] == nil else { throw PresentError.alreadyActive }

        let proxy = OverlayDelegateProxy(sessionID: sessionID, center: self)
        let view = TerminalView(frame: .zero)

        // Same setup order as TerminalCenter and the package's own AppKit
        // example: delegate, then configuration, then controller.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: TerminalCenter.sessionEnvVars(for: sessionID)
        )
        view.controller = TerminalController(
            terminalConfiguration: TerminalCenter.terminalConfiguration
        )

        active[sessionID] = Active(
            sessionID: sessionID,
            view: view,
            command: command,
            delegateProxy: proxy
        )
        reviewSessionIDs.insert(sessionID)
    }

    /// Arms delivery for each mounted overlay, once. Called by
    /// `TerminalHostView` after it mounts the overlays: nothing can happen
    /// before the view is in the hierarchy, because libghostty builds the
    /// surface only then.
    ///
    /// Arming is not typing. The command is typed by `deliverCommandIfReady`
    /// once the surface has actually attached — which is a later, unpredictable
    /// run-loop turn. The previous version typed exactly one turn after mount
    /// and, whenever the surface had not been built by then, sent the command
    /// into a nil surface where `sendText` silently drops it: the review never
    /// started and the overlay sat at a bare shell.
    func deliverCommandsIfNeeded() {
        // Snapshot the sessions to arm before mutating: `deliverCommandIfReady`
        // can type and write back synchronously (when the surface is already
        // attached), and mutating `active` while iterating it would be unsafe.
        let pending = active.compactMap { sessionID, entry in
            entry.view.superview != nil && !entry.deliveryScheduled && !entry.didDeliver
                ? sessionID : nil
        }
        for sessionID in pending {
            guard var entry = active[sessionID] else { continue }
            entry.deliveryScheduled = true
            active[sessionID] = entry
            deliverCommandIfReady(forSession: sessionID)
        }
    }

    /// Called by an overlay's delegate proxy once libghostty has built its
    /// surface. This is the signal the command was waiting for.
    func handleSurfaceAttached(sessionID: String) {
        guard var entry = active[sessionID] else { return }
        entry.surfaceAttached = true
        active[sessionID] = entry
        NSLog("Agents: overlay surface attached for session \(sessionID)")
        deliverCommandIfReady(forSession: sessionID)
    }

    /// Called by an overlay's delegate proxy when its surface is torn down.
    /// Anything typed after this would go nowhere, so the overlay stops
    /// counting as writable until the next attach.
    func handleSurfaceDetached(sessionID: String) {
        guard var entry = active[sessionID] else { return }
        entry.surfaceAttached = false
        active[sessionID] = entry
    }

    /// Types the command if it is armed, not yet sent, and the surface exists.
    /// A no-op otherwise; whichever of arming and surface-attach comes second
    /// drives it.
    private func deliverCommandIfReady(forSession sessionID: String) {
        guard var current = active[sessionID],
              current.deliveryScheduled,
              !current.didDeliver,
              current.surfaceAttached
        else { return }

        current.didDeliver = true
        active[sessionID] = current
        NSLog("Agents: typed review command into the overlay for session \(sessionID)")
        // `exec` so the command replaces the login shell rather than running
        // as its child: the surface then closes when the command exits, with
        // no leftover shell sitting at a prompt for the user to dismiss.
        textDelivery(current.view, "exec \(current.command)\n")
    }

    /// Cancels `sessionID`'s review, if it has one: tears the overlay down
    /// and reports `.cancelled` so the waiting launcher is unblocked with a
    /// failure. Called (via `TerminalCenter.onSessionTeardown`) whenever a
    /// session is closed or quiesced — a review must never outlive, or hang
    /// the launcher of, a session that is going away.
    func cancelReview(forSession sessionID: String) {
        guard dismissOverlay(forSession: sessionID) else { return }
        onClosed?(sessionID, .cancelled)
    }

    /// Called by an overlay's delegate proxy when its command exits.
    func handleProcessExit(sessionID: String) {
        guard dismissOverlay(forSession: sessionID) else { return }
        onClosed?(sessionID, .finished)
    }

    /// Tears down `sessionID`'s overlay and returns whether one existed.
    /// Explicitly clearing the controller calls Ghostty's synchronous
    /// surface-free path before returning, matching
    /// `TerminalCenter.closeSession` — ARC is not the lifecycle boundary.
    private func dismissOverlay(forSession sessionID: String) -> Bool {
        guard let current = active.removeValue(forKey: sessionID) else { return false }
        reviewSessionIDs.remove(sessionID)
        current.delegateProxy.suppressesProcessExit = true
        current.view.delegate = nil
        current.view.removeFromSuperview()
        current.view.controller = nil
        return true
    }
}

/// Delegate for an overlay surface. Separate from `SessionDelegateProxy`
/// because that one routes into attention, title, and OMP-event handling —
/// none of which an overlay has or wants. Two signals matter here: "the
/// surface exists" (which gates typing the command — see `OverlayCenter`)
/// and "the command exited".
///
/// The package dispatches every specialized delegate by conditional-casting
/// the single `view.delegate` object, so these conformances are the whole
/// registration: drop one and its callbacks silently stop arriving.
@MainActor
final class OverlayDelegateProxy:
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceLifecycleDelegate
{
    let sessionID: String
    weak var center: OverlayCenter?
    var suppressesProcessExit = false

    init(sessionID: String, center: OverlayCenter) {
        self.sessionID = sessionID
        self.center = center
    }

    func terminalDidClose(processAlive: Bool) {
        guard !suppressesProcessExit else { return }
        center?.handleProcessExit(sessionID: sessionID)
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        center?.handleSurfaceAttached(sessionID: sessionID)
    }

    func terminalDidDetachSurface() {
        center?.handleSurfaceDetached(sessionID: sessionID)
    }
}
