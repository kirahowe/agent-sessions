import AppKit
import Combine
import GhosttyTerminal

/// Owns the lifecycle of every live TerminalView/TerminalController pair,
/// one per session. Scoped strictly to terminal lifecycle (create/get/close);
/// NSView container/subview/constraint/visibility/focus mechanics live in
/// `TerminalHostView`.
@MainActor
final class TerminalCenter: ObservableObject, SessionTerminating {
    private struct Entry {
        let view: TerminalView
        var controller: TerminalController?
        var delegateProxy: SessionDelegateProxy
        var restoredResume: SessionResumeMetadata?
        var resumeHintScheduled = false
        var didShowResumeHint = false
    }

    private var entries: [String: Entry] = [:]
    @Published private(set) var quiescedSessionIDs: Set<String> = []

    private let textDelivery: @MainActor (TerminalView, String) -> Void

    init(
        textDelivery: @escaping @MainActor (TerminalView, String) -> Void = { view, text in
            view.sendText(text)
        }
    ) {
        self.textDelivery = textDelivery
    }

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

    /// Extra environment variables stamped into every spawned session's
    /// shell, via `TerminalSurfaceOptions.envVars`.
    ///
    /// Extracted to a static for the same reason as `terminalConfiguration`
    /// above — so it can be asserted on directly in tests, see
    /// `TerminalCenterTests`. This is the app's half of the contract with
    /// `hooks/agents-status.sh`: that hook is registered globally in the
    /// user's Claude Code settings, so it also runs for sessions hosted in
    /// iTerm2 and every other terminal, and it refuses to emit its OSC 777
    /// status escape unless `AGENTS_APP` is present in its environment —
    /// that's the only signal it has for "I'm actually running inside the
    /// Agents app." Dropping this static, or losing it from the options
    /// passed to `TerminalSurfaceOptions` below, silently disables every
    /// session's status indicator in the sidebar with no error to point at:
    /// the hook just sees an unset variable and exits 0 before ever writing
    /// its escape, so nothing in this app's logs would even hint at why the
    /// dots stopped appearing.
    static let sessionEnvVars: [String: String] = [
        "AGENTS_APP": "1",
        "WARP_CLI_AGENT_PROTOCOL_VERSION": "1",
        // Where to reach this instance's control socket. A process running in
        // this surface can then ask the app for a full-pane overlay without
        // discovering anything: not which app hosts it, and — since the path
        // carries both the bundle id and the pid that bound it — not which
        // build either, nor which launch of that build, so a review can never
        // surface in another build's app or contend with another instance of
        // this same build. See ControlServer for the protocol and why it
        // isn't AppleScript.
        "AGENTS_CONTROL_SOCK": ControlServer.socketPath,
    ]

    /// Invoked with the session id after the underlying shell process exits
    /// and the terminal has already been torn down.
    var onProcessExit: ((String) -> Void)?

    /// Invoked with the session id and an `AttentionSignal` whenever a
    /// session's terminal reports something that could bear on attention
    /// state, via `SessionDelegateProxy`. See `SessionTerminating.onSessionSignal`.
    var onSessionSignal: ((String, AttentionSignal) -> Void)?

    /// Invoked with the session id and new title whenever a session's
    /// terminal reports an OSC window-title change via
    /// `SessionDelegateProxy.terminalDidChangeTitle`.
    var onTitleChange: ((String, String) -> Void)?

    /// Invoked with a decoded agent session event, either Warp's CLI-agent
    /// protocol (OMP) or the app's own hook title (Claude Code, Codex).
    /// Notifications with either magic title that fail decoding are
    /// consumed by the delegate proxy and never arrive here or at the
    /// attention classifier.
    var onAgentSessionEvent: ((String, AgentSessionEvent) -> Void)?

    /// Lazily creates (on first call) or returns the cached `TerminalView`
    /// for a session, spawning the user's login shell rooted at
    /// `workingDirectory`.
    func terminalView(
        for sessionID: String,
        workingDirectory: String,
        restoredResume: SessionResumeMetadata?
    ) -> TerminalView? {
        guard !quiescedSessionIDs.contains(sessionID) else { return nil }

        if var entry = entries[sessionID] {
            if entry.controller == nil {
                let proxy = SessionDelegateProxy(sessionID: sessionID, center: self)
                let controller = TerminalController(
                    terminalConfiguration: Self.terminalConfiguration
                )
                entry.delegateProxy = proxy
                entry.controller = controller
                entry.restoredResume = restoredResume
                entry.resumeHintScheduled = false
                entry.didShowResumeHint = false
                entry.view.delegate = proxy
                entries[sessionID] = entry
                entry.view.controller = controller
            }
            return entry.view
        }

        let proxy = SessionDelegateProxy(sessionID: sessionID, center: self)
        // DropTerminalView adds Finder drag-and-drop (the package itself has
        // none) — see its doc comment for why. The stored type stays
        // TerminalView; every caller only needs the base API.
        let view = DropTerminalView(frame: .zero)

        // Setup order mirrors the package's own AppKit example: delegate,
        // then configuration, then controller, before the caller adds the
        // view to the hierarchy.
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: Self.sessionEnvVars
        )
        let controller = TerminalController(terminalConfiguration: Self.terminalConfiguration)
        view.controller = controller

        entries[sessionID] = Entry(
            view: view,
            controller: controller,
            delegateProxy: proxy,
            restoredResume: restoredResume
        )
        return view
    }

    /// Prints a resume hint exactly once, and only when metadata was already
    /// present when this live surface was created. Metadata learned from an
    /// agent running in the current surface is intentionally never injected
    /// back into that active session.
    func showResumeHintIfNeeded(for sessionID: String) {
        guard var entry = entries[sessionID],
              entry.view.superview != nil,
              !entry.resumeHintScheduled,
              !entry.didShowResumeHint,
              entry.restoredResume != nil
        else { return }

        // Give AppKit one run-loop turn to create the Ghostty surface after
        // the view enters the hierarchy; sendText is intentionally a no-op
        // before that surface exists.
        entry.resumeHintScheduled = true
        entries[sessionID] = entry
        DispatchQueue.main.async { [weak self] in
            self?.deliverResumeHint(for: sessionID)
        }
    }

    private func deliverResumeHint(for sessionID: String) {
        guard var entry = entries[sessionID],
              entry.resumeHintScheduled,
              !entry.didShowResumeHint,
              let metadata = entry.restoredResume
        else { return }

        entry.didShowResumeHint = true
        entries[sessionID] = entry
        textDelivery(
            entry.view,
            SessionResumeMetadata.resumeHintCommand(for: metadata)
        )
    }

    /// Permanently tears down a session terminal. Explicitly clearing the
    /// controller calls Ghostty's synchronous surface-free path before this
    /// method returns; ARC is not used as the lifecycle boundary.
    func closeSession(_ sessionID: String) {
        quiescedSessionIDs.remove(sessionID)
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        entry.delegateProxy.suppressesProcessExit = true
        entry.view.delegate = nil
        entry.view.removeFromSuperview()
        entry.view.controller = nil
    }

    /// Prevents target processes from writing during a manager operation.
    /// Clearing TerminalView.controller synchronously tears down and calls
    /// ghostty_surface_free before returning.
    func quiesceSessions(_ ids: Set<String>) async {
        quiescedSessionIDs.formUnion(ids)
        for sessionID in ids {
            guard var entry = entries[sessionID] else { continue }
            entry.delegateProxy.suppressesProcessExit = true
            entry.view.delegate = nil
            entry.view.removeFromSuperview()
            entry.view.controller = nil
            entry.controller = nil
            entry.resumeHintScheduled = false
            entry.didShowResumeHint = false
            entries[sessionID] = entry
        }
    }

    func resumeSessions(_ ids: Set<String>) {
        quiescedSessionIDs.subtract(ids)
    }

    func isSessionQuiesced(_ sessionID: String) -> Bool {
        quiescedSessionIDs.contains(sessionID)
    }

    /// Ignores process-exit delivery while a close operation owns terminal
    /// teardown, so persisted rows survive until the manager succeeds.
    func handleProcessExit(sessionID: String) {
        guard !quiescedSessionIDs.contains(sessionID) else { return }
        closeSession(sessionID)
        onProcessExit?(sessionID)
    }

    /// Called by a session's delegate proxy with any signal that could bear
    /// on attention state. Just forwards — no terminal-lifecycle teardown
    /// needed here, unlike `handleProcessExit`.
    func handleSessionSignal(sessionID: String, signal: AttentionSignal) {
        onSessionSignal?(sessionID, signal)
    }

    /// Called by a session's delegate proxy when the shell reports a new OSC
    /// window title. Just forwards — same reasoning as `handleSessionSignal`.
    func handleTitleChange(sessionID: String, title: String) {
        onTitleChange?(sessionID, title)
    }

    func handleAgentSessionEvent(sessionID: String, event: AgentSessionEvent) {
        onAgentSessionEvent?(sessionID, event)
    }
}

/// Small per-session delegate that closes over a session id and forwards to
/// `TerminalCenter`. Each session needs its own instance since neither
/// delegate callback carries the sender's identity. `TerminalView.delegate`
/// is weak, so `TerminalCenter` retains this object itself (alongside the
/// view/controller in its cache entry).
@MainActor
final class SessionDelegateProxy:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceProgressReportDelegate
{
    let sessionID: String
    weak var center: TerminalCenter?
    var suppressesProcessExit = false
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
        guard !suppressesProcessExit else { return }
        center?.handleProcessExit(sessionID: sessionID)
    }

    /// The package dispatches every specialized delegate by conditional-
    /// casting the single `view.delegate` object (see
    /// `TerminalCallbackBridge.handleAction`), so this conformance alone is
    /// all the registration this proxy needs — nothing else has to opt it
    /// in.
    ///
    /// Session-resume notifications take a separate route: valid version-1
    /// envelopes under either Warp's CLI-agent title (OMP) or the app's own
    /// hook title (Claude Code, Codex, via `agents:session`) are forwarded
    /// as agent session events, while every malformed or unsupported
    /// notification carrying either magic title is consumed. Neither kind
    /// is allowed to fall through to fuzzy attention — the hook emits
    /// `agents:session` on every prompt, and letting a malformed one fall
    /// through to keyword classification would raise a bogus gold dot each
    /// time.
    ///
    /// Other notifications are split between the structured `agents:status`
    /// protocol and free text for `AttentionClassifier`; all attention-state
    /// decisions remain in `SessionAttention.reduce`.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        if AgentSessionEvent.isSessionNotification(title: title) {
            if let event = AgentSessionEvent.parseNotification(title: title, body: body) {
                center?.handleAgentSessionEvent(sessionID: sessionID, event: event)
            }
            return
        }

        let signal: AttentionSignal
        if let message = SessionActivity.parseStatusMessage(title: title, body: body) {
            signal = .structured(message)
        } else {
            signal = .notification(title: title, body: body)
        }
        center?.handleSessionSignal(sessionID: sessionID, signal: signal)
    }

    /// A bare BEL — the lowest-fidelity signal in the whole design, carrying
    /// no text at all to classify.
    ///
    /// Shells do ring the bell for their own reasons (an ambiguous tab
    /// completion, a readline error), so this is noisier than a notification.
    /// Three properties keep that harmless rather than annoying: the reducer
    /// may only ever *raise* on a bell and never downgrade an existing
    /// `.blocked`, bells for the session the user is already looking at are
    /// dropped, and any session speaking the structured protocol ignores
    /// them outright. The bells that survive all three come from a
    /// background session the user isn't watching — which is exactly the
    /// case where an agent ringing the bell means what it says.
    ///
    /// The BEL that terminates an OSC sequence doesn't reach here: the
    /// parser consumes it as a string terminator, so our own hook's
    /// `\033]777;...\a` never doubles as a bell.
    func terminalDidRingBell() {
        center?.handleSessionSignal(sessionID: sessionID, signal: .bell)
    }

    /// OSC 9;4 progress reporting, mapped to a semantic signal HERE rather
    /// than carried into the reducer — `TerminalProgressState` is a
    /// libghostty type, and `SessionAttention` stays Foundation-only.
    ///
    /// `percent` is deliberately ignored. Nothing in this design renders a
    /// progress bar; the only question being asked of a progress report is
    /// whether the agent is demonstrably alive and working, and the state
    /// alone answers that.
    ///
    /// `.remove` is dropped rather than mapped: it means the emitter tore
    /// its progress bar down, which is equally consistent with "finished"
    /// and "gave up / was interrupted." With no way to tell those apart,
    /// raising would cry wolf on an abandoned task and clearing would hide
    /// a finished one, so the honest move is to say nothing and let a
    /// notification or the hook speak instead.
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?) {
        let signal: AttentionSignal
        switch state {
        case .set, .indeterminate:
            signal = .working
        case .error, .pause:
            // Both mean the run stopped short of finishing and is sitting
            // there — a raise, at the same fidelity as a bell: something
            // wants the user, with nothing to say what.
            signal = .bell
        case .remove:
            return
        }
        center?.handleSessionSignal(sessionID: sessionID, signal: signal)
    }
}
