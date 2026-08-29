import AppKit
import Combine
import GhosttyTerminal

/// Owns the single full-pane *overlay* terminal: a transient surface that
/// covers the whole detail pane, runs exactly one command, and vanishes when
/// that command exits.
///
/// This exists for terminal review tools — revdiff, driven by the Claude Code
/// plugin's launcher override — that are themselves full-screen TUIs. The
/// agent asking for the review is already running inside a session terminal
/// and already owns that tty with its own full-screen UI, so a TUI it spawns
/// has nowhere to draw. Every other terminal revdiff supports answers this
/// with a split pane or a popup window; this app answers it by taking the
/// pane over, which is what the surrounding sidebar UI makes natural. The
/// session underneath stays selected and keeps running — it simply isn't the
/// thing on screen for the moment, and comes back untouched on exit.
///
/// Deliberately NOT modelled as a session: overlays are never persisted,
/// never appear in the sidebar, and never survive a relaunch. `TerminalCenter`
/// is keyed by session id and coupled to `AppStore`'s persisted rows; an
/// overlay has neither, so making it a session would mean teaching every one
/// of those paths about a row that must never be saved. A separate owner with
/// a single slot is both smaller and impossible to accidentally persist.
///
/// One overlay at a time, by construction. The pane can only show one thing,
/// and a queue would mean a review silently waiting behind another review with
/// no UI to explain the delay — so a second request while one is live is
/// refused, and the caller reports that rather than blocking.
@MainActor
final class OverlayCenter: ObservableObject {
    /// Why a command string rather than a `TerminalSurfaceOptions` command:
    /// libghostty's exec backend spawns the user's login shell and offers no
    /// argv override (see `TerminalSessionBackend` — it is `.exec` or an
    /// in-memory session, nothing more). Handing the command to that shell as
    /// typed input is the same mechanism the OMP resume hint already uses, so
    /// it is a path this app is known to work on rather than a new one.
    private struct Active {
        let id: String
        let view: TerminalView
        let command: String
        let delegateProxy: OverlayDelegateProxy
        var deliveryScheduled = false
        var didDeliver = false
    }

    enum PresentError: Error {
        case alreadyActive
    }

    /// Published so `TerminalHostView` re-renders on present/dismiss. The
    /// `Active` record itself stays private: SwiftUI only needs to know that
    /// the overlay changed, not what is in it.
    @Published private(set) var activeID: String?

    private var active: Active?

    private let textDelivery: @MainActor (TerminalView, String) -> Void

    init(
        textDelivery: @escaping @MainActor (TerminalView, String) -> Void = { view, text in
            view.sendText(text)
        }
    ) {
        self.textDelivery = textDelivery
    }

    /// Invoked with the overlay id after its command exits and the surface has
    /// been torn down. The control server uses this to unblock the launcher.
    var onFinished: ((String) -> Void)?

    var currentView: TerminalView? { active?.view }

    /// Creates the overlay surface and returns its id. The command is not sent
    /// here — the surface has to be in the view hierarchy first, so delivery
    /// waits for `deliverCommandIfNeeded()`; see that method for why.
    func present(command: String, workingDirectory: String) throws -> String {
        guard active == nil else { throw PresentError.alreadyActive }

        let id = UUID().uuidString
        let proxy = OverlayDelegateProxy(overlayID: id, center: self)
        let view = TerminalView(frame: .zero)

        // Same setup order as TerminalCenter and the package's own AppKit
        // example: delegate, then configuration, then controller.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: TerminalCenter.sessionEnvVars
        )
        view.controller = TerminalController(
            terminalConfiguration: TerminalCenter.terminalConfiguration
        )

        active = Active(id: id, view: view, command: command, delegateProxy: proxy)
        activeID = id
        return id
    }

    /// Sends the command once, after the surface exists.
    ///
    /// `sendText` is a silent no-op before libghostty has created the surface,
    /// which does not happen until the view is in the hierarchy — so this is
    /// called by `TerminalHostView` after it mounts the overlay, and defers one
    /// further run-loop turn to let AppKit finish. Exactly the shape of
    /// `TerminalCenter.showResumeHintIfNeeded`, and for exactly the same
    /// reason; if that one's timing ever needs revisiting, this one does too.
    func deliverCommandIfNeeded() {
        guard var current = active,
              current.view.superview != nil,
              !current.deliveryScheduled,
              !current.didDeliver
        else { return }

        current.deliveryScheduled = true
        active = current
        DispatchQueue.main.async { [weak self] in
            self?.deliverCommand()
        }
    }

    private func deliverCommand() {
        guard var current = active, current.deliveryScheduled, !current.didDeliver
        else { return }

        current.didDeliver = true
        active = current
        // `exec` so the command replaces the login shell rather than running
        // as its child: the surface then closes when the command exits, with
        // no leftover shell sitting at a prompt for the user to dismiss.
        textDelivery(current.view, "exec \(current.command)\n")
    }

    /// Tears the overlay down. Explicitly clearing the controller calls
    /// Ghostty's synchronous surface-free path before returning, matching
    /// `TerminalCenter.closeSession` — ARC is not the lifecycle boundary.
    func dismiss() {
        guard let current = active else { return }
        active = nil
        activeID = nil
        current.delegateProxy.suppressesProcessExit = true
        current.view.delegate = nil
        current.view.removeFromSuperview()
        current.view.controller = nil
    }

    /// Called by the overlay's delegate proxy when its command exits.
    func handleProcessExit(overlayID: String) {
        guard active?.id == overlayID else { return }
        dismiss()
        onFinished?(overlayID)
    }
}

/// Delegate for the overlay surface. Separate from `SessionDelegateProxy`
/// because that one closes over a session id and routes into attention,
/// title, and OMP-event handling — none of which an overlay has or wants. The
/// only signal that matters here is "the command exited."
@MainActor
final class OverlayDelegateProxy: TerminalSurfaceCloseDelegate {
    let overlayID: String
    weak var center: OverlayCenter?
    var suppressesProcessExit = false

    init(overlayID: String, center: OverlayCenter) {
        self.overlayID = overlayID
        self.center = center
    }

    func terminalDidClose(processAlive: Bool) {
        guard !suppressesProcessExit else { return }
        center?.handleProcessExit(overlayID: overlayID)
    }
}
