import AppKit
import Combine
import GhosttyTerminal

/// Owns the lifecycle of every live TerminalView/TerminalController pair.
/// Surfaces are keyed by *pane* id and grouped by session: each session owns
/// a `SessionPaneLayout` (see PaneLayout.swift) whose leaves are panes, with
/// a single pane as the degenerate tree. Scoped strictly to terminal + layout
/// lifecycle (create/split/close/focus); NSView container/subview/visibility
/// mechanics live in `TerminalHostView`.
@MainActor
final class TerminalCenter: ObservableObject, SessionTerminating {
    /// One live pane surface. `lastTitle` remembers the pane's most recent
    /// OSC title so the session row can switch to it when this pane gains
    /// focus — the focused pane's title drives the row title, and a pane
    /// that announced its title while unfocused must not lose it.
    private struct PaneEntry {
        let sessionID: String
        let view: TerminalView
        var controller: TerminalController?
        var delegateProxy: SessionDelegateProxy
        var lastTitle: String?
        /// When the pane is safe to type into — the surface built, the shell
        /// at its prompt — kept as a pure state machine so the transitions
        /// are unit-tested without a live surface (see `TerminalReadiness`).
        var readiness = TerminalReadiness()
    }

    /// Per-session resume-hint bookkeeping. Session-scoped, not pane-scoped:
    /// the hint prints once per restored session, and only ever into the
    /// session's initial pane (see `SessionPaneLayout.initialPane`).
    private struct ResumeHintState {
        var metadata: SessionResumeMetadata?
        var scheduled = false
        var didShow = false
    }

    private var panes: [UUID: PaneEntry] = [:]
    private var resumeHints: [String: ResumeHintState] = [:]

    /// Who owns each session's current resume record. Distinct from the
    /// resume DESIGNATE (who may author next): while the author lives, only
    /// its titles may relabel the record; a record whose author is gone is
    /// `.frozen` — it still describes that dead (or pre-relaunch) agent's
    /// conversation, and letting the inheriting designate's title onto it
    /// would advertise "Task B … --resume A" — until a new agent event
    /// re-authors it. Absent means no record exists yet, the one state in
    /// which the designate may pre-label (seed) freely.
    private enum ResumeAuthorship {
        /// A live pane's agent authored the record.
        case pane(UUID)
        /// A record exists but nothing living authored it: restored from
        /// disk, or its author's process died (pane exit or quiesce).
        case frozen
    }

    private var resumeAuthorship: [String: ResumeAuthorship] = [:]

    /// Every session's pane arrangement, published so `TerminalHostView`
    /// re-lays-out on split/close/focus/resize. The pane entries themselves
    /// stay private — observers get views via `view(forPane:)`.
    @Published private(set) var layouts: [String: SessionPaneLayout] = [:]

    @Published private(set) var quiescedSessionIDs: Set<String> = []

    private let textDelivery: @MainActor (TerminalView, String) -> Void
    /// How long after the first prompt signal to wait before typing — the
    /// title arrives from precmd, a moment before the line editor takes the
    /// tty into raw mode, and bytes landing in that gap are echoed twice.
    private let promptSettleDelay: TimeInterval
    /// How long after the surface attaches to wait for a prompt signal
    /// before typing anyway.
    private let promptFallbackDelay: TimeInterval

    /// Both delays are injectable so tests can run the state machine
    /// synchronously (zero) or hold the fallback off entirely.
    init(
        textDelivery: @escaping @MainActor (TerminalView, String) -> Void = { view, text in
            // The readiness gate below is what keeps this from ever being
            // false; if it is, say so — a paste with no surface used to be a
            // silent no-op, and a lost banner is otherwise undiagnosable.
            if !view.paste(text: text) {
                NSLog("Agents: dropped typed text — the pane has no surface")
            }
        },
        promptSettleDelay: TimeInterval = 0.1,
        promptFallbackDelay: TimeInterval = 3.0
    ) {
        self.textDelivery = textDelivery
        self.promptSettleDelay = promptSettleDelay
        self.promptFallbackDelay = promptFallbackDelay
    }

    /// Runs `work` on the main actor after `delay`; synchronously when the
    /// delay is zero, so a test can drive the whole sequence without
    /// waiting on the run loop.
    private func after(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        if delay <= 0 {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        }
    }

    /// The terminal configuration applied to every session's controller,
    /// via `TerminalController`'s `terminalConfiguration:` parameter.
    ///
    /// Extracted to a static so it can be asserted on directly in tests —
    /// see `TerminalCenterTests`. Two things here are load-bearing and will
    /// silently regress if dropped:
    ///
    /// - `term`: every spawned shell advertises `xterm-256color`, the one
    ///   TERM every host and ncurses app already knows. libghostty-spm 1.5
    ///   does bundle an `xterm-ghostty` terminfo and exports it to child
    ///   processes, so the default TERM would now work locally — whether to
    ///   drop this override (and accept `xterm-ghostty` over ssh to hosts
    ///   without that entry) is an open decision, tracked in `.issues`.
    /// - the four brand colours: dropping them costs the app its visual
    ///   identity, with no error to point at why.
    static let terminalConfiguration = TerminalConfiguration { builder in
        // Pinned to xterm-256color rather than the package's default
        // xterm-ghostty — see the doc comment above.
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
    /// iTerm2 and every other terminal, and it refuses to report anything
    /// unless `AGENTS_APP` and the socket/session/pane variables below are
    /// present in its environment — that's the only signal it has for "I'm
    /// actually running inside the Agents app." Dropping this function, or
    /// losing it from the options passed to `TerminalSurfaceOptions` below,
    /// silently disables every session's status indicator and every restore
    /// banner with no error to point at: the hook just sees unset variables
    /// and exits 0 before ever connecting, so nothing in this app's logs
    /// would even hint at why the dots stopped appearing.
    ///
    /// A function of the session id, not a constant: `AGENTS_SESSION_ID` is
    /// what lets a process inside the session say which session it is when it
    /// talks back over the control socket — the revdiff launcher forwards it
    /// so its review can be scoped to the row that asked, rather than taking
    /// over whatever is selected. Every pane of a session shares the
    /// session's id: reviews are per session, not per pane, so an agent in
    /// any pane names the same row. The hook's reports, by contrast, ARE per
    /// pane — each pane is its own agent with its own attention state, and
    /// only the resume designate's agent may author the row's resume record
    /// — so a pane also gets `AGENTS_PANE_ID`, the one thing that lets the
    /// socket (shared by every pane) tell the reporting panes apart. A
    /// surface that is not a pane (an overlay) passes no pane id and gets
    /// no such variable.
    static func sessionEnvVars(for sessionID: String, paneID: UUID? = nil) -> [String: String] {
        var env = [
            "AGENTS_APP": "1",
            "AGENTS_SESSION_ID": sessionID,
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
        if let paneID {
            env["AGENTS_PANE_ID"] = paneID.uuidString
        }
        return env
    }

    /// Invoked with the session id after the session's last pane's shell
    /// process exits and the terminal has already been torn down. A pane
    /// exit that leaves other panes alive collapses the layout instead and
    /// never reaches this.
    var onProcessExit: ((String) -> Void)?

    /// Invoked with (sessionID, paneID, signal) whenever any of a session's
    /// panes reports something that could bear on attention state, via
    /// `SessionDelegateProxy`. The pane id rides along so `AppStore` can
    /// reduce each pane's stream separately before folding the results into
    /// the one session-row indicator. See `SessionTerminating.onSessionSignal`.
    var onSessionSignal: ((String, UUID, AttentionSignal) -> Void)?

    /// Invoked with (sessionID, paneID) after any pane's surface is freed,
    /// on every teardown path. See `SessionTerminating.onPaneClosed`.
    var onPaneClosed: ((String, UUID) -> Void)?

    /// Invoked with (sessionID, title, roles) whenever a pane whose title
    /// matters reports an OSC window-title change (via
    /// `SessionDelegateProxy.terminalDidChangeTitle`), and again with the
    /// newly focused pane's remembered title whenever focus moves to a pane
    /// that has one. The focused pane's title drives the row's display name
    /// (`.display`); the resume-designate pane's labels the resume metadata
    /// (`.resume`). See `SessionTerminating.onTitleChange`.
    var onTitleChange: ((String, String, SessionTitleRoles) -> Void)?

    /// Invoked with a decoded agent session event, either Warp's CLI-agent
    /// protocol (OMP) or the app's own hook title (Claude Code, Codex),
    /// plus the authoring pane's current OSC title as the label seed — see
    /// `SessionTerminating.onAgentSessionEvent`. Notifications with either
    /// magic title that fail decoding are consumed by the delegate proxy
    /// and never arrive here or at the attention classifier.
    var onAgentSessionEvent: ((String, AgentSessionEvent, String?) -> Void)?

    /// Invoked with the session id at the START of every teardown path —
    /// `closeSession` and `quiesceSessions` — before the surface is freed.
    /// This is the single choke point every close route funnels through
    /// (user close, project removal, workspace close/quiesce, process exit),
    /// which is what `OverlayCenter` hooks to cancel a session's open review
    /// and unblock its waiting launcher rather than leaving it hanging on a
    /// connection nobody will ever answer.
    var onSessionTeardown: ((String) -> Void)?

    // MARK: - Session and pane creation

    /// Lazily creates (on first call) or returns the cached focused pane's
    /// `TerminalView` for a session, spawning the user's login shell rooted
    /// at `workingDirectory` for a brand-new session.
    func terminalView(
        for sessionID: String,
        workingDirectory: String,
        restoredResume: SessionResumeMetadata?
    ) -> TerminalView? {
        guard ensureSession(
            sessionID,
            workingDirectory: workingDirectory,
            restoredResume: restoredResume
        ), let layout = layouts[sessionID] else { return nil }
        return panes[layout.focusedPane]?.view
    }

    /// Makes sure `sessionID` has a live pane layout: creates the initial
    /// pane for a session this center has never seen, and recreates the
    /// controller for a pane whose surface was torn down by a quiesce.
    /// Returns false — creating nothing — while the session is quiesced.
    @discardableResult
    func ensureSession(
        _ sessionID: String,
        workingDirectory: String,
        restoredResume: SessionResumeMetadata?
    ) -> Bool {
        guard !quiescedSessionIDs.contains(sessionID) else { return false }

        if let layout = layouts[sessionID] {
            for paneID in layout.paneIDs {
                guard var entry = panes[paneID], entry.controller == nil else { continue }
                let proxy = SessionDelegateProxy(sessionID: sessionID, paneID: paneID, center: self)
                let controller = TerminalController(
                    terminalConfiguration: Self.terminalConfiguration
                )
                entry.delegateProxy = proxy
                entry.controller = controller
                entry.view.delegate = proxy
                panes[paneID] = entry
                entry.view.controller = controller
                resumeHints[sessionID] = ResumeHintState(metadata: restoredResume)
                if restoredResume != nil, resumeAuthorship[sessionID] == nil {
                    resumeAuthorship[sessionID] = .frozen
                }
            }
            return true
        }

        let paneID = UUID()
        layouts[sessionID] = SessionPaneLayout(initialPane: paneID)
        resumeHints[sessionID] = ResumeHintState(metadata: restoredResume)
        if restoredResume != nil {
            // A restored row carries a persisted record authored by a
            // process that predates this launch — frozen until an agent
            // event re-authors it, exactly like a record whose author died.
            resumeAuthorship[sessionID] = .frozen
        }
        panes[paneID] = makePane(
            sessionID: sessionID, paneID: paneID, workingDirectory: workingDirectory
        )
        return true
    }

    /// Spawns a fresh pane surface: the user's login shell in
    /// `workingDirectory`, with the session's stamped environment (shared
    /// `AGENTS_SESSION_ID` included). Setup order mirrors the package's own
    /// AppKit example: delegate, then configuration, then controller, before
    /// the caller adds the view to the hierarchy.
    private func makePane(
        sessionID: String, paneID: UUID, workingDirectory: String
    ) -> PaneEntry {
        let proxy = SessionDelegateProxy(sessionID: sessionID, paneID: paneID, center: self)
        // DropTerminalView adds Finder drag-and-drop (the package itself has
        // none) — see its doc comment for why. Per pane, so drag and drop
        // stays fully native in every pane. The stored type stays
        // TerminalView; every caller only needs the base API.
        let view = DropTerminalView(frame: .zero)
        view.delegate = proxy
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: Self.sessionEnvVars(for: sessionID, paneID: paneID)
        )
        let controller = TerminalController(terminalConfiguration: Self.terminalConfiguration)
        view.controller = controller
        // The pane id is what the hook reports under, so a refusal in the
        // hook's log ("unknown pane …") can be matched against this line.
        NSLog("Agents: spawned pane \(paneID.uuidString) for session \(sessionID)")
        return PaneEntry(
            sessionID: sessionID, view: view, controller: controller, delegateProxy: proxy
        )
    }

    /// The live view for a pane id, if any. `TerminalHostView` mounts every
    /// pane of the selected session through this.
    func view(forPane paneID: UUID) -> TerminalView? {
        panes[paneID]?.view
    }

    // MARK: - Split/close/focus commands

    /// Splits the selected session's focused pane, spawning a fresh login
    /// shell in `workingDirectory`. Returns the new pane's id (now focused),
    /// or nil for a session with no live layout (never shown, or quiesced).
    @discardableResult
    func splitPane(
        in sessionID: String, axis: SplitAxis, workingDirectory: String
    ) -> UUID? {
        guard !quiescedSessionIDs.contains(sessionID), var layout = layouts[sessionID] else {
            return nil
        }
        let paneID = UUID()
        panes[paneID] = makePane(
            sessionID: sessionID, paneID: paneID, workingDirectory: workingDirectory
        )
        layout.splitFocused(axis: axis, adding: paneID)
        layouts[sessionID] = layout
        // No title emit: the new pane is focused and hasn't announced a
        // title yet, so the row keeps its current name until it does.
        return paneID
    }

    /// Closes the focused pane of a multi-pane session, killing its process.
    /// Refuses (returns false) for a single-pane session: closing the last
    /// pane is closing the session, and that decision belongs to the
    /// explicit close-session command, not a pane command.
    @discardableResult
    func closeFocusedPane(in sessionID: String) -> Bool {
        guard !quiescedSessionIDs.contains(sessionID),
              let layout = layouts[sessionID],
              layout.paneCount > 1
        else { return false }
        removePane(layout.focusedPane, from: sessionID)
        return true
    }

    /// Moves a session's focus to `paneID` (click-to-focus). No-op when the
    /// pane is unknown or already focused.
    func focusPane(_ paneID: UUID) {
        guard let sessionID = panes[paneID]?.sessionID,
              var layout = layouts[sessionID],
              layout.focusedPane != paneID
        else { return }
        layout.focus(paneID)
        layouts[sessionID] = layout
        emitFocusedPaneTitle(for: sessionID)
    }

    /// Moves the session's focus one pane toward `direction`. Returns
    /// whether focus moved (false at an edge).
    @discardableResult
    func moveFocus(in sessionID: String, direction: FocusDirection) -> Bool {
        guard var layout = layouts[sessionID], layout.moveFocus(direction) else { return false }
        layouts[sessionID] = layout
        emitFocusedPaneTitle(for: sessionID)
        return true
    }

    /// Adjusts a split's ratio (divider drag) — see
    /// `SessionPaneLayout.setRatio`.
    func setRatio(in sessionID: String, at path: [PaneBranch], to ratio: Double) {
        guard var layout = layouts[sessionID] else { return }
        layout.setRatio(at: path, to: ratio)
        layouts[sessionID] = layout
    }

    /// Removes one pane of a multi-pane session: frees its surface, then
    /// collapses its layout node. Callers guarantee the session has another
    /// pane to inherit the space.
    private func removePane(_ paneID: UUID, from sessionID: String) {
        guard var layout = layouts[sessionID] else { return }
        teardownPaneEntry(paneID)
        if case .removed = layout.removePane(paneID) {
            layouts[sessionID] = layout
            // Focus may have moved to the inheriting pane — let its
            // remembered title take over the row.
            emitFocusedPaneTitle(for: sessionID)
        }
    }

    /// Frees one pane's surface. Explicitly clearing the controller calls
    /// Ghostty's synchronous surface-free path before this method returns;
    /// ARC is not used as the lifecycle boundary. Announces the closed pane
    /// afterward so `AppStore` drops its attention contribution.
    private func teardownPaneEntry(_ paneID: UUID) {
        guard let entry = panes.removeValue(forKey: paneID) else { return }
        entry.delegateProxy.suppressesProcessExit = true
        entry.view.delegate = nil
        entry.view.removeFromSuperview()
        entry.view.controller = nil
        onPaneClosed?(entry.sessionID, paneID)
    }

    /// Re-announces the focused pane's remembered title after focus moved.
    /// A pane that never announced one emits nothing: the row keeps its
    /// current name rather than flashing back to a default.
    private func emitFocusedPaneTitle(for sessionID: String) {
        guard let layout = layouts[sessionID],
              let title = panes[layout.focusedPane]?.lastTitle,
              !title.isEmpty
        else { return }
        onTitleChange?(
            sessionID, title,
            titleRoles(of: layout.focusedPane, in: layout, sessionID: sessionID)
        )
    }

    /// Which title roles a pane currently holds — see
    /// `SessionTerminating.onTitleChange`. Empty for a pane that is neither
    /// focused nor allowed to label the resume record.
    private func titleRoles(
        of paneID: UUID, in layout: SessionPaneLayout, sessionID: String
    ) -> SessionTitleRoles {
        var roles: SessionTitleRoles = []
        if layout.focusedPane == paneID { roles.insert(.display) }
        if resumeLabelPane(in: layout, sessionID: sessionID) == paneID { roles.insert(.resume) }
        return roles
    }

    /// The pane whose titles may label the resume record: the record's
    /// author while it lives; nobody while an unowned record stands (frozen
    /// — see `ResumeAuthorship`); the designate before any record exists,
    /// so a title arriving ahead of the first agent event still seeds the
    /// label.
    private func resumeLabelPane(in layout: SessionPaneLayout, sessionID: String) -> UUID? {
        switch resumeAuthorship[sessionID] {
        case .pane(let author):
            return layout.tree.contains(author) ? author : nil
        case .frozen:
            return nil
        case nil:
            return resumeDesignatePane(in: layout)
        }
    }

    // MARK: - Resume hint

    /// Types the restore banner (see `SessionResumeMetadata.restoreInput`)
    /// exactly once per restored session, into the session's initial pane
    /// only, and only when metadata was already present when the live
    /// surface was created. Metadata learned from an agent running in the
    /// current surface is intentionally never injected back into that
    /// active session.
    ///
    /// Delivery waits for the pane to be ready for input, which is two
    /// things (see `TerminalReadiness.isReady`): its surface must exist —
    /// the text goes down the pty, and there is no pty until Ghostty has
    /// built the surface, an arbitrary number of run-loop turns after the
    /// view is mounted — and its shell must have reached a prompt, known
    /// from the pane's first title or, failing that, a timer. Marking the
    /// hint scheduled here and letting whichever signal completes the set
    /// deliver it is what keeps the banner from being lost to a paste
    /// that silently did nothing, or echoed twice by a tty no shell has
    /// taken over yet.
    func showResumeHintIfNeeded(for sessionID: String) {
        guard var hint = resumeHints[sessionID],
              hint.metadata != nil,
              !hint.scheduled,
              !hint.didShow,
              let layout = layouts[sessionID],
              let entry = panes[layout.initialPane],
              entry.view.superview != nil
        else { return }

        hint.scheduled = true
        resumeHints[sessionID] = hint
        deliverResumeHintWhenReady(for: sessionID)
    }

    /// Types the banner once the initial pane is ready for input, after the
    /// settle delay; a no-op until then, and after it has been typed.
    private func deliverResumeHintWhenReady(for sessionID: String) {
        guard let hint = resumeHints[sessionID],
              hint.scheduled, !hint.didShow,
              let layout = layouts[sessionID],
              let entry = panes[layout.initialPane],
              entry.readiness.isReady
        else { return }
        after(promptSettleDelay) { [weak self] in self?.deliverResumeHint(for: sessionID) }
    }

    private func deliverResumeHint(for sessionID: String) {
        guard var hint = resumeHints[sessionID],
              hint.scheduled,
              !hint.didShow,
              let metadata = hint.metadata,
              let layout = layouts[sessionID],
              let entry = panes[layout.initialPane],
              entry.readiness.isReady
        else { return }

        hint.didShow = true
        resumeHints[sessionID] = hint
        NSLog(
            "Agents: typed restore banner into session \(sessionID) pane \(layout.initialPane.uuidString) (\(metadata.agent) \(metadata.sessionID))"
        )
        textDelivery(entry.view, SessionResumeMetadata.restoreInput(for: metadata))
    }

    /// Called by a pane's delegate proxy once Ghostty has built the pane's
    /// surface. Starts the prompt fallback clock, and delivers the
    /// session's restore banner if the surface was the last thing it was
    /// waiting on — see `showResumeHintIfNeeded`.
    func handleSurfaceAttached(paneID: UUID) {
        guard var entry = panes[paneID] else { return }
        let generation = entry.readiness.attach()
        panes[paneID] = entry
        after(promptFallbackDelay) { [weak self] in
            // `noteFallbackElapsed` drops the timer if a detach/attach has
            // since bumped the generation past it — the surface it was armed
            // for is gone.
            guard let self, var entry = self.panes[paneID],
                  entry.readiness.noteFallbackElapsed(generation: generation)
            else { return }
            self.panes[paneID] = entry
            self.deliverResumeHintWhenReady(for: entry.sessionID)
        }
        deliverResumeHintWhenReady(for: entry.sessionID)
    }

    /// Called by a pane's delegate proxy when its surface is torn down —
    /// a quiesce, or the view leaving its window. Anything typed after this
    /// would go nowhere, so the pane stops counting as writable until the
    /// next attach, and the next surface's shell starts from scratch.
    func handleSurfaceDetached(paneID: UUID) {
        guard var entry = panes[paneID] else { return }
        entry.readiness.detach()
        panes[paneID] = entry
    }

    // MARK: - Session teardown

    /// Permanently tears down every pane of a session.
    func closeSession(_ sessionID: String) {
        onSessionTeardown?(sessionID)
        quiescedSessionIDs.remove(sessionID)
        resumeHints.removeValue(forKey: sessionID)
        resumeAuthorship.removeValue(forKey: sessionID)
        guard let layout = layouts.removeValue(forKey: sessionID) else { return }
        for paneID in layout.paneIDs {
            teardownPaneEntry(paneID)
        }
    }

    /// Prevents target processes from writing during a manager operation.
    /// Clearing TerminalView.controller synchronously tears down and calls
    /// ghostty_surface_free before returning.
    ///
    /// Split layout is not preserved across a quiesce: the processes don't
    /// survive, so the session resumes as a single pane — the same rule as
    /// app relaunch. One pane's *view* is kept for reuse (the initial pane's
    /// where it still exists) so lazy recreation after resume restores the
    /// same NSView identity the pre-pane code did; every other pane is torn
    /// down outright.
    func quiesceSessions(_ ids: Set<String>) async {
        for sessionID in ids {
            onSessionTeardown?(sessionID)
        }
        quiescedSessionIDs.formUnion(ids)
        for sessionID in ids {
            guard let layout = layouts[sessionID] else { continue }
            let survivor = resumeDesignatePane(in: layout)
            for paneID in layout.paneIDs where paneID != survivor {
                teardownPaneEntry(paneID)
            }
            guard var entry = panes[survivor] else { continue }
            entry.delegateProxy.suppressesProcessExit = true
            entry.view.delegate = nil
            entry.view.removeFromSuperview()
            entry.view.controller = nil
            entry.controller = nil
            entry.lastTitle = nil
            // The delegate was detached above, so the surface's own detach
            // callback never arrives: reset readiness by hand, or the banner
            // typed after resume could go to a surface that no longer exists
            // — and be lost, since a paste says nothing then — or to a fresh
            // shell that is not at its prompt yet.
            entry.readiness.detach()
            panes[survivor] = entry
            // The survivor keeps its view and its pane id, but its PROCESS
            // is as dead as its siblings' — announce the closure so its
            // attention contribution is dropped. Without this, a structured
            // latch or a blocked state from the old shell would carry over
            // onto the fresh shell spawned after resume, under the same
            // reused pane id.
            onPaneClosed?(sessionID, survivor)
            // Any record's author dies with its process, but the RECORD
            // survives the quiesce in AppStore — freeze it (never clear to
            // absent, which would let the fresh shell's first decorated
            // title relabel the old conversation's id) until a new agent
            // event re-authors it. A session that never had a record keeps
            // having none, and its fresh shell may seed one.
            if resumeAuthorship[sessionID] != nil {
                resumeAuthorship[sessionID] = .frozen
            }
            layouts[sessionID] = SessionPaneLayout(initialPane: survivor)
            if var hint = resumeHints[sessionID] {
                hint.scheduled = false
                hint.didShow = false
                resumeHints[sessionID] = hint
            }
        }
    }

    func resumeSessions(_ ids: Set<String>) {
        quiescedSessionIDs.subtract(ids)
    }

    func isSessionQuiesced(_ sessionID: String) -> Bool {
        quiescedSessionIDs.contains(sessionID)
    }

    // MARK: - Delegate-proxy entry points

    /// Called by a pane's delegate proxy when its shell process exits. A
    /// multi-pane session collapses the exited pane's node and carries on;
    /// the last pane's exit removes the whole session through the existing
    /// close path. Ignored while a close operation owns terminal teardown
    /// (quiesce), so persisted rows survive until the manager succeeds.
    func handleProcessExit(paneID: UUID) {
        guard let entry = panes[paneID] else { return }
        let sessionID = entry.sessionID
        guard !quiescedSessionIDs.contains(sessionID) else { return }
        if let layout = layouts[sessionID], layout.paneCount > 1 {
            removePane(paneID, from: sessionID)
            return
        }
        closeSession(sessionID)
        onProcessExit?(sessionID)
    }

    /// Called by a pane's delegate proxy with any signal that could bear on
    /// attention state. Forwarded with both ids: the session id names the
    /// row that lights up, the pane id names the stream being reduced.
    func handleSessionSignal(sessionID: String, paneID: UUID, signal: AttentionSignal) {
        onSessionSignal?(sessionID, paneID, signal)
    }

    /// Called by a pane's delegate proxy when its shell reports a new OSC
    /// window title. Always remembered on the pane; forwarded with the
    /// roles the pane holds — a title from a pane that is neither focused
    /// nor the resume designate is remembered but never forwarded (see
    /// `onTitleChange`).
    func handleTitleChange(paneID: UUID, title: String) {
        guard var entry = panes[paneID] else { return }
        entry.lastTitle = title
        // The first title is the shell's first prompt — see
        // `PaneEntry.promptSeen` — and may be what the restore banner
        // was waiting on.
        let firstPrompt = entry.readiness.notePrompt()
        panes[paneID] = entry
        if firstPrompt {
            deliverResumeHintWhenReady(for: entry.sessionID)
        }
        guard let layout = layouts[entry.sessionID] else { return }
        let roles = titleRoles(of: paneID, in: layout, sessionID: entry.sessionID)
        guard !roles.isEmpty else { return }
        onTitleChange?(entry.sessionID, title, roles)
    }

    /// Called by a pane's delegate proxy with a decoded agent session
    /// event. Forwarded only from the session's resume-designate pane: the
    /// row keeps ONE resume metadata record (`SessionRow.resume`), and the
    /// hint built from it is later injected into the initial pane — so only
    /// the agent running where that hint will land may write it. An agent
    /// in any other pane would otherwise overwrite it, and after a relaunch
    /// its `--resume` command would be typed into a different agent's pane.
    /// A session with no layout (not seen by this center) forwards
    /// unfiltered — there is no designate to check against, and dropping
    /// would be the lie.
    ///
    /// Deliberate: metadata recorded by a designate that later CLOSES is
    /// kept, not invalidated. The whole point of resume metadata is
    /// outliving its process — the dead agent's conversation is still
    /// genuinely resumable, and the row survives through its other panes
    /// (single-pane sessions never hit this: the last pane's exit removes
    /// the row and the metadata with it). The record is stale only until
    /// the NEW designate's agent next announces itself, which the hook
    /// does on every prompt.
    func handleAgentSessionEvent(sessionID: String, paneID: UUID, event: AgentSessionEvent) {
        if let layout = layouts[sessionID], resumeDesignatePane(in: layout) != paneID {
            return
        }
        resumeAuthorship[sessionID] = .pane(paneID)
        onAgentSessionEvent?(sessionID, event, panes[paneID]?.lastTitle)
    }

    /// Applies one hook event delivered over the control socket, returning
    /// a refusal for the hook (nil on success). The socket can't tell which
    /// pane a connection came from — every pane of a session shares one
    /// endpoint — so the pane id the hook read from `AGENTS_PANE_ID` is
    /// checked against the live pane table, and against the session it
    /// claims, before anything is applied: a stale id from a torn-down pane
    /// must not light up or relabel whichever pane inherited the row, and a
    /// quiesced survivor keeps its id for the fresh shell that follows but
    /// has no process that could honestly report for it in between. From
    /// there the two halves take exactly the paths their pty-borne forms
    /// do: the status through `handleSessionSignal` as a structured
    /// message, the announcement through `handleAgentSessionEvent` with its
    /// resume-designate rule intact.
    func handleControlSessionEvent(_ event: ControlSessionEvent) -> String? {
        guard let entry = panes[event.pane], entry.sessionID == event.session else {
            return "unknown pane \(event.pane.uuidString) in session \(event.session)"
        }
        guard entry.controller != nil else {
            return "pane \(event.pane.uuidString) has no live process"
        }
        if let status = event.status {
            handleSessionSignal(
                sessionID: event.session, paneID: event.pane, signal: .structured(status)
            )
        }
        if let agentEvent = event.event {
            handleAgentSessionEvent(sessionID: event.session, paneID: event.pane, event: agentEvent)
        }
        return nil
    }

    /// The pane whose agent owns the session's resume metadata, and the
    /// pane a quiesce keeps: the initial pane while it lives, else the
    /// first remaining leaf. The two uses must stay the same pane — the
    /// resume hint is delivered into the survivor, so the survivor's agent
    /// must be the one whose metadata was recorded.
    private func resumeDesignatePane(in layout: SessionPaneLayout) -> UUID {
        layout.tree.contains(layout.initialPane) ? layout.initialPane : layout.paneIDs[0]
    }
}

/// Small per-pane delegate that closes over a pane id (and the session it
/// belongs to) and forwards to `TerminalCenter`. Each pane needs its own
/// instance since no delegate callback carries the sender's identity.
/// Attention/title/agent-event callbacks carry the session id — those
/// signals aggregate to the session row — while process exit and title
/// changes are routed by pane id so the center can collapse the right layout
/// node and apply the focused-pane title rule. `TerminalView.delegate` is
/// weak, so `TerminalCenter` retains this object itself (alongside the
/// view/controller in its pane entry).
@MainActor
final class SessionDelegateProxy:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceProgressReportDelegate,
    TerminalSurfaceLifecycleDelegate
{
    let sessionID: String
    let paneID: UUID
    weak var center: TerminalCenter?
    var suppressesProcessExit = false
    init(sessionID: String, paneID: UUID, center: TerminalCenter) {
        self.sessionID = sessionID
        self.paneID = paneID
        self.center = center
    }

    func terminalDidChangeTitle(_ title: String) {
        // The focused pane's OSC title becomes the session's display name
        // (sidebar + window title) unless the user has manually renamed it,
        // and also the window subtitle — see SessionRow.displayName/subtitle
        // and AppStore.setSessionTitle, which persists it onto the row.
        center?.handleTitleChange(paneID: paneID, title: title)
    }

    func terminalDidClose(processAlive: Bool) {
        guard !suppressesProcessExit else { return }
        center?.handleProcessExit(paneID: paneID)
    }

    /// The surface — and with it the pty — now exists. This is the signal
    /// the restore banner waits for: see `TerminalCenter.handleSurfaceAttached`.
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        center?.handleSurfaceAttached(paneID: paneID)
    }

    func terminalDidDetachSurface() {
        center?.handleSurfaceDetached(paneID: paneID)
    }

    /// The package dispatches every specialized delegate by conditional-
    /// casting the single `view.delegate` object (see
    /// `TerminalCallbackBridge.handleAction`), so this conformance alone is
    /// all the registration this proxy needs — nothing else has to opt it
    /// in.
    ///
    /// Session-resume notifications take a separate route: valid version-1
    /// envelopes under either Warp's CLI-agent title (OMP) or the
    /// `agents:session` title (any emitter still using the OSC form; the
    /// bundled hook now reports over the control socket instead — see
    /// `handleControlSessionEvent`) are forwarded as agent session events,
    /// while every malformed or unsupported notification carrying either
    /// magic title is consumed. Neither kind is allowed to fall through to
    /// fuzzy attention — an emitter may announce on every prompt, and
    /// letting a malformed one fall through to keyword classification
    /// would raise a bogus gold dot each time.
    ///
    /// Other notifications are split between the structured `agents:status`
    /// protocol and free text for `AttentionClassifier`; all attention-state
    /// decisions remain in `SessionAttention.reduce`.
    func terminalDidRequestDesktopNotification(title: String, body: String) {
        if AgentSessionEvent.isSessionNotification(title: title) {
            if let event = AgentSessionEvent.parseNotification(title: title, body: body) {
                center?.handleAgentSessionEvent(sessionID: sessionID, paneID: paneID, event: event)
            }
            return
        }

        let signal: AttentionSignal
        if let message = SessionActivity.parseStatusMessage(title: title, body: body) {
            signal = .structured(message)
        } else {
            signal = .notification(title: title, body: body)
        }
        center?.handleSessionSignal(sessionID: sessionID, paneID: paneID, signal: signal)
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
        center?.handleSessionSignal(sessionID: sessionID, paneID: paneID, signal: .bell)
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
        center?.handleSessionSignal(sessionID: sessionID, paneID: paneID, signal: signal)
    }
}
