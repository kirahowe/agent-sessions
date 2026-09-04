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
/// - the command is sent **once**, and only once the surface has attached —
///   `sendText` is a silent no-op before libghostty has built the surface, so
///   a send that races ahead of it is not an error, just a review that never
///   starts, and the user is left looking at a bare login shell where revdiff
///   should be;
/// - the command is `exec`'d, so the surface closes when it exits rather than
///   dropping the user at a shell prompt they have to dismiss by hand;
/// - a process exit both frees the session's slot and fires `onClosed`, which
///   is the only thing that ever unblocks the waiting launcher;
/// - reviews are per session: one session's review must never block, replace,
///   or outlive another session's.
@MainActor
final class OverlayCenterTests: XCTestCase {
    func testPresentRefusesASecondOverlayForTheSameSession() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
        try overlays.present(command: "/tmp/first.sh", workingDirectory: "/tmp", sessionID: "s1")

        XCTAssertThrowsError(
            try overlays.present(command: "/tmp/second.sh", workingDirectory: "/tmp", sessionID: "s1"),
            "a second concurrent overlay for one session must be refused — its pane can only show one review, and queuing would leave the second caller blocked with no UI explaining the wait"
        ) { error in
            XCTAssertEqual(error as? OverlayCenter.PresentError, .alreadyActive)
        }
    }

    func testDifferentSessionsReviewConcurrently() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
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
    }

    /// The core of the fix. The surface is built an unpredictable number of
    /// run-loop turns after the view mounts, and `sendText` is a silent
    /// no-op until it exists. The previous version typed exactly one turn
    /// after mount, so whenever the surface was not ready yet the command
    /// vanished and the overlay sat at a bare shell — the intermittent
    /// "empty terminal" this whole type exists to prevent.
    func testCommandIsTypedOnlyOnceTheSurfaceHasAttached() async throws {
        var delivered: [String] = []
        let overlays = OverlayCenter(textDelivery: { _, text in delivered.append(text) })
        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")

        // Not mounted yet: delivering here would be swallowed by libghostty.
        overlays.deliverCommandsIfNeeded()
        await drainMainQueue()
        XCTAssertTrue(
            delivered.isEmpty,
            "the command was sent before the surface entered the view hierarchy, where sendText is a silent no-op — the review would never start"
        )

        let host = NSView()
        host.addSubview(try XCTUnwrap(overlays.view(forSession: "s1")))
        overlays.deliverCommandsIfNeeded()
        await drainMainQueue()
        XCTAssertTrue(
            delivered.isEmpty,
            "mounting is not attachment: the surface is built only once the view has a real size in a window, so typing at mount time dropped the command whenever that build had not happened yet — exactly the intermittent empty-terminal failure"
        )

        overlays.handleSurfaceAttached(sessionID: "s1")
        XCTAssertEqual(
            delivered,
            ["exec /tmp/review.sh\n"],
            "the command must be typed exactly once the surface attaches, and via exec — repeated sends would run the review twice, and dropping exec would leave a shell prompt behind after it quits"
        )

        overlays.handleSurfaceAttached(sessionID: "s1")
        overlays.deliverCommandsIfNeeded()
        overlays.handleSurfaceDetached(sessionID: "s1")
        overlays.handleSurfaceAttached(sessionID: "s1")
        await drainMainQueue()
        XCTAssertEqual(delivered.count, 1, "a repeat attach, a repeat arm, or a surface rebuilt later must not run the review a second time")
    }

    /// Arming (from `TerminalHostView`) and the surface attaching have no
    /// fixed order. Whichever lands second must be the one that types.
    func testCommandIsTypedWhenAttachComesBeforeArming() async throws {
        var delivered: [String] = []
        let overlays = OverlayCenter(textDelivery: { _, text in delivered.append(text) })
        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let host = NSView()
        host.addSubview(try XCTUnwrap(overlays.view(forSession: "s1")))

        overlays.handleSurfaceAttached(sessionID: "s1")
        XCTAssertTrue(delivered.isEmpty, "an attached surface must not type before the host has armed delivery")

        overlays.deliverCommandsIfNeeded()
        XCTAssertEqual(delivered, ["exec /tmp/review.sh\n"])
    }

    /// A review requested by a session that isn't on screen is mounted
    /// hidden by `TerminalHostView`; its command must still be delivered —
    /// the review runs behind the scenes and is simply revealed later. An
    /// overlay that was never mounted must not type even once its surface
    /// attaches, because it was never armed.
    func testCommandDeliveryIgnoresOnlyUnmountedOverlays() async throws {
        var delivered: [String] = []
        let overlays = OverlayCenter(textDelivery: { _, text in delivered.append(text) })
        try overlays.present(command: "/tmp/mounted.sh", workingDirectory: "/tmp", sessionID: "s1")
        try overlays.present(command: "/tmp/unmounted.sh", workingDirectory: "/tmp", sessionID: "s2")

        let host = NSView()
        let mounted = try XCTUnwrap(overlays.view(forSession: "s1"))
        host.addSubview(mounted)
        mounted.isHidden = true

        overlays.deliverCommandsIfNeeded()
        overlays.handleSurfaceAttached(sessionID: "s1")
        overlays.handleSurfaceAttached(sessionID: "s2")
        await drainMainQueue()

        XCTAssertEqual(
            delivered,
            ["exec /tmp/mounted.sh\n"],
            "a mounted-but-hidden overlay must still receive its command (a background session's review has to actually start), while an unmounted one must not — it was never armed, so even its surface attaching must not type"
        )
    }

    /// The package finds this delegate by conditional cast on the single
    /// `view.delegate`, so conformance is the entire registration. Without
    /// the lifecycle conformance the overlay never learns its surface exists
    /// and the command is never typed at all.
    func testOverlayProxyReceivesSurfaceLifecycle() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
        try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp", sessionID: "s1")
        let view = try XCTUnwrap(overlays.view(forSession: "s1"))
        let proxy = try XCTUnwrap(view.delegate as? OverlayDelegateProxy)
        XCTAssertTrue(
            proxy is any TerminalSurfaceLifecycleDelegate,
            "without the lifecycle conformance libghostty never calls back with the attached surface, so the review command is never typed"
        )
        XCTAssertTrue(
            proxy is any TerminalSurfaceCloseDelegate,
            "without the close conformance a finished review never fires onClosed, hanging the launcher forever"
        )
    }

    func testProcessExitDismissesAndFreesTheSessionSlot() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
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
            "onClosed(.finished) is the only signal that unblocks the launcher waiting on the control socket — without it a finished review hangs its caller forever"
        )
        XCTAssertNil(overlays.view(forSession: "s1"))
        XCTAssertTrue(overlays.reviewSessionIDs.isEmpty)
        XCTAssertNil(view.controller, "the surface must be freed synchronously on dismissal, as TerminalCenter.closeSession does — ARC is not the lifecycle boundary here")
        XCTAssertNoThrow(
            try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp", sessionID: "s1"),
            "the slot must be free once a review exits, or the first review of a session would be the only one ever possible"
        )
    }

    /// Cancelling is the session-teardown path (close, quiesce, process
    /// exit): the overlay is torn down AND the launcher is answered with a
    /// failure. Both halves matter — skipping the answer leaves the launcher
    /// blocked forever on a connection nobody will write to.
    func testCancelReviewReportsCancelledAndTearsDown() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
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
        let overlays = OverlayCenter(textDelivery: { _, _ in })
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

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
