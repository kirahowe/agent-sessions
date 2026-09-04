import AppKit
import Darwin
import GhosttyTerminal
import XCTest
@testable import Agents

/// `OverlayCenter` is what lets a review TUI (revdiff, via the Claude Code
/// plugin's launcher override) take the detail pane — scoped to the session
/// that asked for it. The properties pinned here are the ones the launcher's
/// contract actually rests on, each of which fails silently rather than
/// loudly if it regresses:
///
/// - the review command is the surface's OWN process, spawned by libghostty
///   from `TerminalSurfaceOptions.command` the moment the surface is built —
///   nothing is ever typed, so there is no readiness race and no login shell
///   where revdiff should be;
/// - that command is bash source to Ghostty's embedded runtime, so it is the
///   bundled `overlay-run.sh` wrapper, a completion token minted for this
///   review, and the review script, each quoted;
/// - the wrapper setting the terminal title to that token is what ends a
///   review — the surface itself stays open after its command exits,
///   whatever `waitAfterCommand` says — and it both frees the session's slot
///   and fires `onClosed`, the only thing that ever unblocks the waiting
///   launcher; the surface closing (a keypress at "Process exited") is the
///   fallback for the same, and any other title is ignored;
/// - reviews are per session: one session's review must never block, replace,
///   or outlive another session's.
@MainActor
final class OverlayCenterTests: XCTestCase {
    func testPresentRefusesASecondOverlayForTheSameSession() throws {
        let overlays = OverlayCenter()
        try overlays.present(command: "/tmp/first.sh", workingDirectory: "/tmp", sessionID: "s1")

        XCTAssertThrowsError(
            try overlays.present(command: "/tmp/second.sh", workingDirectory: "/tmp", sessionID: "s1"),
            "a second concurrent overlay for one session must be refused — its pane can only show one review, and queuing would leave the second caller blocked with no UI explaining the wait"
        ) { error in
            XCTAssertEqual(error as? OverlayCenter.PresentError, .alreadyActive)
        }
    }

    func testDifferentSessionsReviewConcurrently() throws {
        let overlays = OverlayCenter()
        try overlays.present(command: "/tmp/first.sh", workingDirectory: "/tmp", sessionID: "s1")

        XCTAssertNoThrow(
            try overlays.present(command: "/tmp/second.sh", workingDirectory: "/tmp", sessionID: "s2"),
            "reviews are scoped per session — one session's open review must not refuse another session's request, or a busy teammate session would block reviews everywhere"
        )
        XCTAssertEqual(overlays.reviewSessionIDs, ["s1", "s2"])
        XCTAssertNotNil(overlays.view(forSession: "s1"))
        XCTAssertNotNil(overlays.view(forSession: "s2"))
        XCTAssertIdentical(overlays.view(forSession: "s1"), overlays.view(forSession: "s1"))
        XCTAssertNotIdentical(
            overlays.view(forSession: "s1"),
            overlays.view(forSession: "s2"),
            "each session's review must own its own surface — sharing one would interleave two TUIs into a single terminal"
        )
        let tokens = try ["s1", "s2"].map { try XCTUnwrap(overlays.view(forSession: $0)?.delegate as? OverlayDelegateProxy).completionToken }
        XCTAssertNotEqual(tokens[0], tokens[1], "completion tokens are minted per review — a shared one would let either wrapper end the other's review")
    }

    /// The core of the mechanism: the review command is handed to libghostty
    /// as the surface's own process, not typed into a shell. Ghostty's
    /// embedded runtime treats the string as bash source (it becomes
    /// `exec -l <string>` under `login`), so it is the bundled wrapper with
    /// the review script as its argument, each single-quoted — a Debug build
    /// lives in "Agents Dev.app", space included, and the launcher's script
    /// path is whatever `TMPDIR` made it. The working directory and the
    /// session's environment (which carries `AGENTS_SESSION_ID`, so the
    /// review scopes back to its row) ride along on the same options.
    func testPresentConfiguresTheSurfaceToRunTheReviewCommand() throws {
        let overlays = OverlayCenter(
            wrapperURL: URL(fileURLWithPath: "/Applications/Agents Dev.app/Contents/Resources/overlay-run.sh")
        )
        try overlays.present(
            command: "/tmp/it's here/review.sh", workingDirectory: "/tmp/repo", sessionID: "s1"
        )

        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let token = try XCTUnwrap(view.delegate as? OverlayDelegateProxy).completionToken
        XCTAssertNotNil(UUID(uuidString: token), "the completion token is a fresh UUID — nothing a review's output could contain by chance, got \(token)")
        let options = view.configuration
        XCTAssertEqual(
            options.command,
            "'/Applications/Agents Dev.app/Contents/Resources/overlay-run.sh' '\(token)' '/tmp/it'\\''s here/review.sh'",
            "the surface's command must be the bundled wrapper running the review script with this review's token, each quoted for bash — the runtime hands this string to `exec -l`, where an unquoted space splits a path and a `direct:` prefix is exec'd as a program name"
        )
        XCTAssertNil(
            options.waitAfterCommand,
            "waitAfterCommand must be left unset: Ghostty holds a surface spawned with a command open regardless, and the option can only agree — passing false would document an intent the runtime cannot honour, hiding that the app closes the surface itself on the wrapper's command-finished mark"
        )
        XCTAssertEqual(
            options.workingDirectory, "/tmp/repo",
            "the review runs in the working directory the launcher passed — its script does not cd, so the surface's cwd is where revdiff diffs"
        )
        XCTAssertEqual(
            options.envVars["AGENTS_SESSION_ID"], "s1",
            "the overlay's process must carry its session id, the same way a pane does, so anything it spawns can reach the app for this exact session"
        )
        guard case .exec = options.backend else {
            return XCTFail("an overlay must use the exec backend — an in-memory session has no process to run the review as")
        }
    }

    /// The command is set once, at `present`, and never re-delivered. What
    /// this can pin without a live surface: mounting does not re-touch the
    /// configured command, and the proxy has no surface-attach hook — the
    /// one callback the old type-at-attach delivery hung off. A typing path
    /// reintroduced some other way would not fail here; the bundled-wrapper
    /// and command-line tests, plus the live E2E, are what pin "nothing is
    /// typed" beyond that.
    func testPresentIsTheOnlyThingThatConfiguresTheCommand() throws {
        let overlays = OverlayCenter()
        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let configuredCommand = view.configuration.command

        // Mounting is what used to trigger delivery; it must now be inert with
        // respect to the command.
        let host = NSView()
        host.addSubview(view)

        XCTAssertEqual(
            view.configuration.command, configuredCommand,
            "mounting the overlay view must not re-touch the command — it is the surface's spawn argv, fixed at present, not something delivered on a later run-loop turn"
        )
        XCTAssertFalse(
            view.delegate is any TerminalSurfaceLifecycleDelegate,
            "the overlay proxy must not adopt the surface-lifecycle delegate — that attach callback is where typed delivery used to hang, and there is nothing left to deliver"
        )
    }

    /// What the launcher forwards (PATH and friends, from the shell that
    /// asked) reaches the surface's process — laid UNDER the session's own
    /// variables, so a request cannot re-point the review at another session
    /// or another app instance by forwarding those.
    func testPresentLaysTheForwardedEnvironmentUnderTheSessionsOwn() throws {
        let overlays = OverlayCenter()
        try overlays.present(
            command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1",
            environment: [
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                "LANG": "en_GB.UTF-8",
                "AGENTS_SESSION_ID": "someone-else",
                "AGENTS_CONTROL_SOCK": "/tmp/not-this-app.sock",
            ]
        )

        let envVars = try XCTUnwrap(overlays.view(forSession: "s1")).configuration.envVars
        XCTAssertEqual(
            envVars["PATH"], "/opt/homebrew/bin:/usr/bin:/bin",
            "the caller's PATH must reach the review — inside a Finder-launched app it is the only PATH that knows where jj and git live"
        )
        XCTAssertEqual(envVars["LANG"], "en_GB.UTF-8")
        XCTAssertEqual(
            envVars["AGENTS_SESSION_ID"], "s1",
            "the session's identity must win over anything forwarded — otherwise a request could scope its review, and every hook fired from inside it, to a different session"
        )
        XCTAssertEqual(
            envVars["AGENTS_CONTROL_SOCK"], ControlServer.socketPath,
            "the app's own socket must win over a forwarded one, or processes inside the review would report to a different app instance"
        )
    }

    /// The package finds these delegates by conditional cast on the single
    /// `view.delegate`, so conformance is the entire registration. Both
    /// matter: the title callback is how a review normally ends (the wrapper
    /// sets the completion token as the title; the surface stays open after
    /// its command exits, so no close comes on its own), and the close
    /// callback is the fallback for a keypress at Ghostty's "Process exited"
    /// line. Drop both and a finished review hangs its launcher forever. The
    /// overlay needs no surface-lifecycle callback — its command is spawned
    /// by libghostty as the surface is built, not typed in afterward — so
    /// the proxy deliberately does not implement
    /// `TerminalSurfaceLifecycleDelegate`.
    func testOverlayProxyReceivesTitleAndCloseCallbacks() throws {
        let overlays = OverlayCenter()
        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let proxy = try XCTUnwrap(view.delegate as? OverlayDelegateProxy)
        XCTAssertTrue(
            proxy is any TerminalSurfaceTitleDelegate,
            "without the title conformance the wrapper's completion token is never seen and every review waits for a keypress before its launcher is answered"
        )
        XCTAssertTrue(
            proxy is any TerminalSurfaceCloseDelegate,
            "without the close conformance a review whose mark never arrived hangs its launcher forever, even after the user closes the surface"
        )
    }

    /// The normal end of a review: the wrapper sets the completion token as
    /// the title while the surface is still open, and the app is what tears
    /// the surface down.
    func testCompletionTokenDismissesAndFreesTheSessionSlot() throws {
        let overlays = OverlayCenter()
        var closed: [(String, OverlayCenter.ReviewOutcome)] = []
        overlays.onClosed = { closed.append(($0, $1)) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let proxy = try XCTUnwrap(view.delegate as? OverlayDelegateProxy)

        proxy.terminalDidChangeTitle(proxy.completionToken)

        XCTAssertNotNil(
            overlays.view(forSession: "s1"),
            "the title callback arrives from inside libghostty's handling of this surface's own message — dismissing (and freeing the surface) synchronously there would free it under the core mid-call, so the teardown must wait a run-loop turn"
        )
        XCTAssertTrue(closed.isEmpty)
        drainMainQueue()

        XCTAssertEqual(closed.map(\.0), ["s1"])
        XCTAssertEqual(
            closed.map(\.1),
            [.finished],
            "onClosed(.finished) is the only signal that unblocks the launcher waiting on the control socket — and the command-finished mark is the only time it can fire without a keypress, since the surface stays open after its command exits"
        )
        XCTAssertNil(overlays.view(forSession: "s1"))
        XCTAssertTrue(overlays.reviewSessionIDs.isEmpty)
        XCTAssertNil(
            view.controller,
            "the surface must be freed synchronously on dismissal — Ghostty is holding it open at a 'Process exited' line, and nothing else will ever close it"
        )
        XCTAssertNoThrow(
            try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp", sessionID: "s1"),
            "the slot must be free once a review exits, or the first review of a session would be the only one ever possible"
        )

        // Freeing the surface, or a keypress that raced the mark, can still
        // deliver a close to the OLD proxy afterwards — with a new review
        // now occupying the slot.
        proxy.terminalDidClose(processAlive: false)
        XCTAssertEqual(
            closed.count, 1,
            "a close arriving after the finish must not answer the launcher again — its connection is gone, and the reply would go to the review that has since taken the slot"
        )
        XCTAssertNotNil(overlays.view(forSession: "s1"), "the late close must not tear down the review that replaced the finished one")
    }

    /// The fallback end of a review: the surface closed — a keypress at the
    /// exited line, or a process that died without reaching the wrapper's
    /// mark — with no command-finished callback first.
    func testSurfaceCloseDismissesAndFreesTheSessionSlot() throws {
        let overlays = OverlayCenter()
        var closed: [(String, OverlayCenter.ReviewOutcome)] = []
        overlays.onClosed = { closed.append(($0, $1)) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let proxy = try XCTUnwrap(view.delegate as? OverlayDelegateProxy)

        proxy.terminalDidClose(processAlive: false)

        XCTAssertEqual(closed.map(\.0), ["s1"])
        XCTAssertEqual(
            closed.map(\.1),
            [.finished],
            "a close is still a finished review — the launcher's sentinel says whether revdiff ran; the app must not report a user-dismissed overlay as cancelled"
        )
        XCTAssertNil(overlays.view(forSession: "s1"))
        XCTAssertTrue(overlays.reviewSessionIDs.isEmpty)
        XCTAssertNil(view.controller, "the surface must be freed synchronously on dismissal, as TerminalCenter.closeSession does — ARC is not the lifecycle boundary here")
        XCTAssertNoThrow(
            try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp", sessionID: "s1"),
            "the slot must be free once a review exits, or the first review of a session would be the only one ever possible"
        )

        proxy.terminalDidChangeTitle(proxy.completionToken)
        drainMainQueue()
        XCTAssertEqual(closed.count, 1, "a finish arriving after the close must be ignored for the same reason a late close is")
        XCTAssertNotNil(overlays.view(forSession: "s1"))
    }

    /// The finish is deferred a turn and the close is not, so a keypress (or
    /// a process death) landing in that turn closes the surface first. The
    /// launcher must still be answered exactly once, and the deferred finish
    /// must not touch whatever review has since taken the slot.
    func testCloseInsideTheFinishTurnReportsOnce() throws {
        let overlays = OverlayCenter()
        var closed: [(String, OverlayCenter.ReviewOutcome)] = []
        overlays.onClosed = { closed.append(($0, $1)) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let proxy = try XCTUnwrap(overlays.view(forSession: "s1")?.delegate as? OverlayDelegateProxy)

        proxy.terminalDidChangeTitle(proxy.completionToken)
        proxy.terminalDidClose(processAlive: false)
        XCTAssertEqual(closed.map(\.1), [.finished])
        try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp", sessionID: "s1")
        let next = overlays.view(forSession: "s1")

        drainMainQueue()

        XCTAssertEqual(closed.count, 1, "the deferred finish must find its review already gone and stay silent — a second reply would go to the next review's launcher")
        XCTAssertIdentical(overlays.view(forSession: "s1"), next, "the deferred finish must not dismiss the review that took the slot in the meantime")
    }

    /// Titles that are not this review's token — revdiff's own, or anything a
    /// child of the review writes — must not end the review. This is the
    /// property the token exists for: a shell-integration mark could be
    /// produced by a child by accident; a fresh UUID cannot.
    func testAForeignTitleDoesNotEndTheReview() throws {
        let overlays = OverlayCenter()
        var closed: [String] = []
        overlays.onClosed = { sessionID, _ in closed.append(sessionID) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        try overlays.present(command: "/tmp/other.sh", workingDirectory: "/tmp", sessionID: "s2")
        let proxy = try XCTUnwrap(overlays.view(forSession: "s1")?.delegate as? OverlayDelegateProxy)
        let other = try XCTUnwrap(overlays.view(forSession: "s2")?.delegate as? OverlayDelegateProxy)

        proxy.terminalDidChangeTitle("revdiff — 3 files")
        proxy.terminalDidChangeTitle("")
        proxy.terminalDidChangeTitle(other.completionToken)
        drainMainQueue()

        XCTAssertTrue(closed.isEmpty, "a title that is not this review's own token must be ignored — including another review's token")
        XCTAssertNotNil(overlays.view(forSession: "s1"))
        XCTAssertNotNil(overlays.view(forSession: "s2"))
    }

    /// A session going away while its finish is in flight: cancel reports
    /// `.cancelled` at once, and the deferred finish must neither report a
    /// second time nor touch the review that has since taken the slot.
    func testCancelInsideTheFinishTurnReportsCancelledOnce() throws {
        let overlays = OverlayCenter()
        var closed: [(String, OverlayCenter.ReviewOutcome)] = []
        overlays.onClosed = { closed.append(($0, $1)) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let proxy = try XCTUnwrap(overlays.view(forSession: "s1")?.delegate as? OverlayDelegateProxy)

        proxy.terminalDidChangeTitle(proxy.completionToken)
        overlays.cancelReview(forSession: "s1")
        XCTAssertEqual(
            closed.map(\.1), [.cancelled],
            "a review torn down by its session's closure must be reported as cancelled even though its command had already finished — the launcher's connection is answered once, and this is the answer that was actually acted on"
        )
        try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp", sessionID: "s1")
        let next = overlays.view(forSession: "s1")

        drainMainQueue()

        XCTAssertEqual(closed.count, 1, "the deferred finish must stay silent after a cancellation — its launcher has already been answered")
        XCTAssertIdentical(overlays.view(forSession: "s1"), next, "the deferred finish must not dismiss the review that took the slot after the cancellation")
    }

    /// Runs the main queue's pending blocks — the deferred finish among them.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    /// A build that lost its wrapper resource cannot run a review at all —
    /// better to say so at the socket than to spawn a surface whose command
    /// bash cannot find.
    func testPresentRefusesToRunWithoutTheWrapper() {
        let overlays = OverlayCenter(wrapperURL: nil)
        XCTAssertThrowsError(
            try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        ) { error in
            XCTAssertEqual(error as? OverlayCenter.PresentError, .wrapperMissing)
        }
        XCTAssertTrue(
            overlays.reviewSessionIDs.isEmpty,
            "a refused present must not leave a phantom review holding the session's slot"
        )
        XCTAssertNil(overlays.view(forSession: "s1"))
    }

    /// The wrapper ships in this test host's app bundle, executable, and does
    /// what the delegate wiring assumes: after the review's own output it
    /// sets the terminal title to the token it was given, and exits with the
    /// review's status. Run directly (not via `sh`) so a resource copy that
    /// dropped the executable bit — which bash's `exec` needs too — fails
    /// here rather than in the first real review.
    func testBundledWrapperSetsTheTokenTitleAfterTheReview() throws {
        let wrapper = try XCTUnwrap(
            OverlayCenter.bundledWrapperURL,
            "overlay-run.sh must ship in the app bundle's Resources — without it no review can run (see the resources build phase in project.yml)"
        )
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlay-wrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let review = directory.appendingPathComponent("review.sh")
        try "#!/bin/sh\nprintf 'review output\\n'\nexit 7\n".write(to: review, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: review.path)

        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["TOKEN-0001", review.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "review output\n\u{1B}]2;TOKEN-0001\u{07}",
            "the wrapper must set the terminal title to its token once the review has ended, and only then — that title is the one exit signal the app gets without a keypress"
        )
        XCTAssertEqual(
            process.terminationStatus, 7,
            "the wrapper must exit with the review's own status — it is transparent to whatever spawned it"
        )
    }

    /// A review killed by a signal — Ctrl-C before the TUI has the tty in raw
    /// mode, a TERM to the process group — reaches the wrapper too. The token
    /// must still be written, or the surface sits at Ghostty's exited line
    /// with the launcher blocked until a further keypress. The tty signals
    /// the whole foreground group; this signals the wrapper and its child
    /// directly, which is the same thing to each of them.
    func testBundledWrapperReportsAReviewKilledBySignal() throws {
        let wrapper = try XCTUnwrap(OverlayCenter.bundledWrapperURL)
        for (signal, name, expectedStatus) in [(SIGINT, "INT", Int32(130)), (SIGTERM, "TERM", Int32(143))] {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("overlay-signal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appendingPathComponent("pid")
            let review = directory.appendingPathComponent("review.sh")
            // The review becomes `sleep` itself (exec), so one pid is the whole
            // review, as a TUI's would be.
            try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n".write(to: review, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: review.path)

            let process = Process()
            process.executableURL = wrapper
            process.arguments = ["TOKEN-\(name)", review.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            var reviewPid: Int32?
            for _ in 0..<200 where reviewPid == nil {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    reviewPid = pid
                } else {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            let review_ = try XCTUnwrap(reviewPid, "the review never started")

            kill(review_, signal)
            kill(process.processIdentifier, signal)
            process.waitUntilExit()

            XCTAssertEqual(
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "\u{1B}]2;TOKEN-\(name)\u{07}",
                "SIG\(name): the wrapper must still set the token title for a review ended by a signal — without it nothing tells the app the review is over until a keypress"
            )
            XCTAssertEqual(process.terminationStatus, expectedStatus, "SIG\(name): the wrapper must exit with the signal's conventional status")
        }
    }

    /// The composed command is evaluated by bash, so the quoting is tested by
    /// bash: every shell-special character must come back verbatim.
    func testShellQuotingSurvivesBashEvaluation() throws {
        let hostile = "it's \"here\" $HOME `date` \\ ; & | *.sh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile", "--norc", "-c", "printf '%s' \(OverlayCenter.shellQuoted(hostile))",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            hostile,
            "a quoted value must survive bash untouched — this is the same evaluation Ghostty's runtime gives the surface command, and a path it mangles is a review that never starts"
        )
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// Cancelling is the session-teardown path (close, quiesce, process
    /// exit): the overlay is torn down AND the launcher is answered with a
    /// failure. Both halves matter — skipping the answer leaves the launcher
    /// blocked forever on a connection nobody will write to.
    func testCancelReviewReportsCancelledAndTearsDown() throws {
        let overlays = OverlayCenter()
        var closed: [(String, OverlayCenter.ReviewOutcome)] = []
        overlays.onClosed = { closed.append(($0, $1)) }

        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        try overlays.present(command: "/tmp/other.sh", workingDirectory: "/tmp", sessionID: "s2")
        let cancelledView = try XCTUnwrap(overlays.view(forSession: "s1"))

        overlays.cancelReview(forSession: "s1")

        XCTAssertEqual(closed.map(\.0), ["s1"])
        XCTAssertEqual(
            closed.map(\.1),
            [.cancelled],
            "a cancelled review must be reported as cancelled, not finished — answering the launcher with success would make the caller believe annotations were collected when the review was actually destroyed"
        )
        XCTAssertNil(overlays.view(forSession: "s1"))
        XCTAssertNil(cancelledView.controller)
        XCTAssertNotNil(
            overlays.view(forSession: "s2"),
            "cancelling one session's review must never touch another session's — that cross-session interference is exactly what session scoping exists to remove"
        )
        XCTAssertEqual(overlays.reviewSessionIDs, ["s2"])
    }

    func testCancelReviewIsANoOpForASessionWithoutOne() {
        let overlays = OverlayCenter()
        var closed: [String] = []
        overlays.onClosed = { sessionID, _ in closed.append(sessionID) }

        overlays.cancelReview(forSession: "s1")

        XCTAssertTrue(
            closed.isEmpty,
            "cancelReview fires on EVERY session teardown, almost none of which have a review open — reporting a closure here would answer a control-socket client that does not exist, or worse, a later one"
        )
    }

    /// The socket path is what makes a Debug build and a Release build — which
    /// differ *only* by bundle id — reachable independently, AND what makes
    /// two launches of the very same build reachable independently too. That
    /// second half is not cosmetic: AgentsTests runs with its TEST_HOST set to
    /// the app bundle, so every test invocation boots the real
    /// `AgentsApp.init` and, without a pid in the path, would bind straight
    /// over a running app's socket file out from under it — leaving that app
    /// listening on an unlinked inode and every subsequent review request
    /// getting ECONNREFUSED. If the path ever collapsed to a fixed name, a
    /// review fired from one build could open in another, or a test run could
    /// silently kill a real app's control channel — both are the class of
    /// failure a URL scheme was rejected for.
    func testControlSocketPathIsScopedToTheBundle() {
        let path = ControlServer.socketPath
        let bundleID = Bundle(for: OverlayCenterTests.self).bundleIdentifier
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            path.hasSuffix(".control.\(pid).sock"),
            "the control socket path must carry this process's pid so a test-host launch (or any other second launch of the same build) cannot contend with a running instance's endpoint — unexpected socket path: \(path)"
        )
        XCTAssertTrue(
            path.contains("com.kirahowe.agents"),
            "the control socket path must carry the bundle id so Debug and Release builds cannot collide on one endpoint (got \(path), test bundle \(bundleID ?? "nil"))"
        )
        XCTAssertLessThan(
            path.utf8.count,
            104,
            "sockaddr_un.sun_path is 104 bytes on Darwin — a longer path fails to bind at runtime, silently leaving the app with no control channel"
        )
    }

    /// A crashed instance (or a test-host launch that boots the app and then
    /// exits, see the test above) leaves its per-pid socket file on disk with
    /// nothing listening on it any more. The sweep in `bindAndListen` is what
    /// keeps those from accumulating forever; this exercises it directly
    /// against a temp directory rather than the real Application Support one,
    /// so it can plant a genuinely dead socket without needing an actual crash.
    func testSweepDeadSocketsRemovesOnlyDeadMatchingSockets() throws {
        // Deliberately not FileManager's `temporaryDirectory`: on this
        // machine it resolves under `/var/folders/...`, which alone is
        // already close to the 104-byte `sockaddr_un.sun_path` limit, and a
        // UUID-named subdirectory on top of it would push a socket path over
        // that ceiling before the sweep logic under test ever runs. `/tmp`
        // stays short as the literal string bind(2) sees, even though it is
        // itself a symlink.
        let directory = "/tmp/ctrlsweep-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let prefix = "com.kirahowe.agents.control."
        let deadPath = "\(directory)/\(prefix)111.sock"
        let livePath = "\(directory)/\(prefix)222.sock"
        let unrelatedPath = "\(directory)/not-a-control-socket.txt"
        FileManager.default.createFile(atPath: unrelatedPath, contents: Data("hello".utf8))

        // A dead socket: bind it, then close the fd WITHOUT unlinking. That
        // leaves exactly what a crash leaves — a file at the path with no
        // process on the other end to accept a connection.
        let deadFD = try bindUnixSocket(at: deadPath)
        close(deadFD)

        // A live socket: bind, listen, and keep the fd open for the life of
        // the test so the sweep finds a real listener.
        let liveFD = try bindUnixSocket(at: livePath)
        XCTAssertEqual(listen(liveFD, 1), 0, "failed to listen on the live test socket")
        defer { close(liveFD) }

        ControlServer.sweepDeadSockets(in: directory, prefix: prefix, ownPath: "/nonexistent-own-path")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: deadPath),
            "a socket file with nothing listening on it must be removed by the sweep"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: livePath),
            "a socket with a live listener must never be removed by the sweep"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedPath),
            "a file that doesn't match the control-socket naming scheme must never be touched by the sweep"
        )
    }

    /// Binds (but does not listen on) an AF_UNIX SOCK_STREAM socket at
    /// `path`, returning the bound file descriptor. Shared setup for the
    /// sweep test's dead- and live-socket fixtures.
    private func bindUnixSocket(at path: String) throws -> Int32 {
        struct SocketSetupError: Error, CustomStringConvertible {
            let description: String
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketSetupError(description: "socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketSetupError(description: "test socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // Qualified as `Darwin.bind`: unqualified `bind` inside an NSObject
        // subclass (XCTestCase, here) resolves to Cocoa Bindings'
        // `NSObject.bind(_:to:withKeyPath:options:)` instead of the libc
        // syscall, since member lookup wins over the global function.
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, size)
            }
        }
        guard bound == 0 else {
            throw SocketSetupError(description: "bind() failed: \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// Without this key in the environment, a process inside a session has no
    /// way to find the app hosting it, and the launcher falls through to the
    /// ghostty branch — which drives `tell application "Ghostty"` at an app
    /// that does not exist on this machine.
    func testSessionEnvVarsAdvertisesTheControlSocket() {
        XCTAssertEqual(
            TerminalCenter.sessionEnvVars(for: "some-session")["AGENTS_CONTROL_SOCK"],
            ControlServer.socketPath,
            "sessions must advertise this build's control socket, or revdiff's launcher cannot find the app that owns the terminal it is running in"
        )
    }
}
