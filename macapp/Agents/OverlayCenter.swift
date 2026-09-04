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
    /// The review command is the surface's OWN process, not text typed into a
    /// login shell. `TerminalSurfaceOptions.command` (exposed by
    /// libghostty-spm 1.5) hands the exec backend a command in place of the
    /// user's shell, so the review is running the moment the surface is
    /// built. Nothing is ever typed, so there is no readiness to wait on and
    /// no login shell to `exec` away.
    ///
    /// Two facts about how Ghostty's embedded runtime treats that command
    /// shape everything below, and neither is visible from the package's
    /// option names:
    ///
    /// - The string is bash source, not an argv. On macOS it runs as
    ///   `login -flp <user> bash --noprofile --norc -c "exec -l <string>"`.
    ///   The `direct:` prefix Ghostty's *config file* accepts is parsed by
    ///   the config loader only; handed in here it reaches bash as the name
    ///   of a program to exec, and the review never runs. So `present`
    ///   composes a quoted command line — see `surfaceCommand`.
    /// - A surface spawned with a command is held open after that command
    ///   exits: the runtime forces wait-after-command on, and the package's
    ///   `waitAfterCommand` can only turn it on too. The surface does not
    ///   close, and so does not fire `terminalDidClose`, until a key is
    ///   pressed at Ghostty's "Process exited" line. The exit the launcher
    ///   is waiting on therefore has to be reported another way: the surface
    ///   runs the bundled `overlay-run.sh` wrapper around the review with a
    ///   token minted for this one review, the wrapper sets the terminal
    ///   title to that token once the review has ended (also from its
    ///   signal traps), and libghostty reports every title as
    ///   `terminalDidChangeTitle`. The overlay is torn down when its own
    ///   token arrives — a title no child of the review can produce by
    ///   accident, which a shell-integration mark could. `terminalDidClose`
    ///   stays as the fallback for a keypress or a surface that died some
    ///   other way.
    /// - The process gets the APP's environment, and a Finder-launched app
    ///   has the bare system PATH: no Homebrew, no direnv, no project
    ///   toolchain. The old login shell rebuilt all that from the user's rc
    ///   files; a spawned command has no such step, and no login shell could
    ///   recover per-project environment anyway. So the launcher forwards the
    ///   variables its subprocesses resolve tools and config through, taken
    ///   from the shell that asked for the review, and `present` lays them
    ///   under the session's own variables.
    ///
    /// This replaced typing `exec <command>\n` once the surface attached. That
    /// worked, but it was type-ahead into a freshly spawned shell — inherently
    /// racy against libghostty building the surface, and it left a login shell
    /// in the process tree for the instant before `exec` replaced it. Spawning
    /// the command directly removes both.
    private struct Active {
        let sessionID: String
        let view: TerminalView
        let delegateProxy: OverlayDelegateProxy
    }

    enum PresentError: Error, Equatable, CustomStringConvertible {
        case alreadyActive
        /// The app bundle has no `overlay-run.sh`: a broken build, not a
        /// runtime condition. Refusing the review with a message beats
        /// spawning a surface whose command cannot start.
        case wrapperMissing

        /// Worded for the launcher, which prints the control-socket refusal
        /// verbatim to the agent that asked for the review.
        var description: String {
            switch self {
            case .alreadyActive:
                return "a review is already open in this session"
            case .wrapperMissing:
                return "this Agents build is missing its overlay-run.sh resource — rebuild or reinstall the app"
            }
        }
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

    /// Where the wrapper every overlay runs lives — the bundled resource in
    /// the app, injectable so tests can pin the composed command line
    /// without depending on the test host's install path.
    private let wrapperPath: String?

    /// The wrapper as shipped in this app bundle, if the build carried it.
    /// Nonisolated so it can be `init`'s default argument (default arguments
    /// are evaluated outside the actor); `Bundle.main` is safe from anywhere.
    nonisolated static var bundledWrapperURL: URL? {
        Bundle.main.url(forResource: "overlay-run", withExtension: "sh")
    }

    init(wrapperURL: URL? = OverlayCenter.bundledWrapperURL) {
        wrapperPath = wrapperURL?.path
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
    /// hierarchy, with a real size) before libghostty spawns the command and
    /// the review starts running.
    var allViews: [TerminalView] {
        active.values.map(\.view)
    }

    /// Creates an overlay surface whose own process runs `sessionID`'s review
    /// command. The command starts as soon as libghostty builds the surface —
    /// once `TerminalHostView` has mounted the view and it has a real size —
    /// so there is nothing further to deliver after this.
    ///
    /// `environment` is what the caller forwarded (see the class comment);
    /// the session's own variables win over it, so a request cannot re-point
    /// the review at another session or another app instance.
    func present(
        command: String, workingDirectory: String, sessionID: String,
        environment: [String: String] = [:]
    ) throws {
        guard active[sessionID] == nil else { throw PresentError.alreadyActive }
        guard let wrapperPath else { throw PresentError.wrapperMissing }

        let proxy = OverlayDelegateProxy(
            sessionID: sessionID, completionToken: UUID().uuidString, center: self
        )
        let view = TerminalView(frame: .zero)

        // Same setup order as TerminalCenter and the package's own AppKit
        // example: delegate, then configuration, then controller.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: environment.merging(TerminalCenter.sessionEnvVars(for: sessionID)) { _, session in session },
            command: Self.surfaceCommand(
                wrapper: wrapperPath, token: proxy.completionToken, running: command
            )
            // No `waitAfterCommand`: the runtime holds a surface spawned with
            // a command open regardless, and the option can only agree with
            // it. The exit is observed through the wrapper instead — see the
            // class comment.
        )
        view.controller = TerminalController(
            terminalConfiguration: TerminalCenter.terminalConfiguration
        )

        active[sessionID] = Active(sessionID: sessionID, view: view, delegateProxy: proxy)
        reviewSessionIDs.insert(sessionID)
    }

    /// The `command` handed to libghostty for a review: the bundled wrapper
    /// with this review's completion token and the review command as its
    /// arguments, each single-quoted.
    ///
    /// The runtime treats this string as bash source (see the class comment),
    /// so each word is quoted for bash — and the paths need it: a Debug build
    /// is "Agents Dev.app", space included, and the launcher's script lives
    /// under `TMPDIR`, whose value is nobody's promise.
    static func surfaceCommand(wrapper: String, token: String, running command: String) -> String {
        "\(shellQuoted(wrapper)) \(shellQuoted(token)) \(shellQuoted(command))"
    }

    /// Single-quotes `value` for bash: the one quoting form in which nothing
    /// is special except a single quote, which is spelled `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    /// Called by an overlay's delegate proxy once its review has ended —
    /// normally on the wrapper's command-finished mark, else when the
    /// surface closes.
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
/// none of which an overlay has or wants. Only one thing matters here: the
/// review ended. That arrives as the wrapper setting the terminal title to
/// this review's completion token (`terminalDidChangeTitle`), or — the
/// fallback, since a surface spawned with a command stays open after it
/// exits — as the surface closing (`terminalDidClose`) once the user
/// presses a key. Either dismisses the overlay and answers the launcher;
/// whichever comes second is a no-op.
///
/// The overlay needs no surface-lifecycle callback: its command is spawned by
/// libghostty as the surface is built, not typed in afterward, so nothing
/// waits on "the surface exists".
///
/// The package dispatches every specialized delegate by conditional-casting
/// the single `view.delegate` object, so these conformances are the whole
/// registration: drop one and its callback silently stops arriving. Drop
/// both and a finished review hangs its launcher forever.
@MainActor
final class OverlayDelegateProxy: TerminalSurfaceTitleDelegate, TerminalSurfaceCloseDelegate {
    let sessionID: String
    /// The title the wrapper sets once the review has ended. Minted per
    /// review, so only this review's wrapper can end this review: the
    /// review's own titles, and anything its children write to the pty,
    /// never match it. The overlay displays no title, so nothing is lost by
    /// using the channel this way; a real child-exited signal from the
    /// package would replace it (agents#2).
    let completionToken: String
    weak var center: OverlayCenter?
    var suppressesProcessExit = false

    init(sessionID: String, completionToken: String, center: OverlayCenter) {
        self.sessionID = sessionID
        self.completionToken = completionToken
        self.center = center
    }

    /// Every title the surface sets. The one that matters is the completion
    /// token: the review command has ended, while the surface itself is
    /// still open (and will stay so), which is why this — not the close — is
    /// the signal a review normally ends on.
    ///
    /// Deferred one run-loop turn: the package delivers this synchronously
    /// from inside libghostty's handling of this surface's own message, and
    /// the dismissal frees the surface. Freeing it there would pull it out
    /// from under the core mid-call; a turn later the core is done with it.
    /// (The close callback below is different: closing is the last thing
    /// the core does with a surface on that path, so it acts at once.)
    func terminalDidChangeTitle(_ title: String) {
        guard title == completionToken else { return }
        DispatchQueue.main.async { [weak self] in self?.reviewEnded() }
    }

    /// The surface closed: the user pressed a key at Ghostty's "Process
    /// exited" line, or the process went away without ever writing the
    /// wrapper's token. Same outcome, later.
    func terminalDidClose(processAlive: Bool) {
        reviewEnded()
    }

    private func reviewEnded() {
        guard !suppressesProcessExit else { return }
        center?.handleProcessExit(sessionID: sessionID)
    }
}
