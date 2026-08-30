import AppKit
import Darwin
import GhosttyTerminal
import XCTest
@testable import Agents

/// `OverlayCenter` is what lets a review TUI (revdiff, via the Claude Code
/// plugin's launcher override) take the detail pane. The properties pinned
/// here are the ones the launcher's contract actually rests on, each of which
/// fails silently rather than loudly if it regresses:
///
/// - the command is sent **once**, and only after the surface is mounted —
///   `sendText` is a no-op before libghostty has created the surface, so an
///   early send is not an error, just a review that never starts;
/// - the command is `exec`'d, so the surface closes when it exits rather than
///   dropping the user at a shell prompt they have to dismiss by hand;
/// - a process exit both frees the slot and fires `onFinished`, which is the
///   only thing that ever unblocks the waiting launcher.
@MainActor
final class OverlayCenterTests: XCTestCase {
    func testPresentRefusesASecondConcurrentOverlay() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
        _ = try overlays.present(command: "/tmp/first.sh", workingDirectory: "/tmp")

        XCTAssertThrowsError(
            try overlays.present(command: "/tmp/second.sh", workingDirectory: "/tmp"),
            "a second concurrent overlay must be refused — the pane can only show one review, and queuing would leave the second caller blocked with no UI explaining the wait"
        ) { error in
            XCTAssertEqual(error as? OverlayCenter.PresentError, .alreadyActive)
        }
    }

    func testCommandIsExecdExactlyOnceAfterMounting() async throws {
        var delivered: [String] = []
        let overlays = OverlayCenter(textDelivery: { _, text in delivered.append(text) })
        _ = try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp")

        // Not mounted yet: delivering here would be swallowed by libghostty.
        overlays.deliverCommandIfNeeded()
        await drainMainQueue()
        XCTAssertTrue(
            delivered.isEmpty,
            "the command was sent before the surface entered the view hierarchy, where sendText is a silent no-op — the review would never start"
        )

        let host = NSView()
        host.addSubview(try XCTUnwrap(overlays.currentView))

        overlays.deliverCommandIfNeeded()
        overlays.deliverCommandIfNeeded()
        await drainMainQueue()
        overlays.deliverCommandIfNeeded()
        await drainMainQueue()

        XCTAssertEqual(
            delivered,
            ["exec /tmp/review.sh\n"],
            "the overlay command must be sent exactly once and via exec — repeated sends would run the review twice, and dropping exec would leave a shell prompt behind after it quits"
        )
    }

    func testProcessExitDismissesAndFreesTheSlot() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
        var finished: [String] = []
        overlays.onFinished = { finished.append($0) }

        let id = try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp")
        let view = try XCTUnwrap(overlays.currentView)
        let proxy = try XCTUnwrap(view.delegate as? OverlayDelegateProxy)

        proxy.terminalDidClose(processAlive: false)

        XCTAssertEqual(
            finished,
            [id],
            "onFinished is the only signal that unblocks the launcher waiting on the control socket — without it a finished review hangs its caller forever"
        )
        XCTAssertNil(overlays.currentView)
        XCTAssertNil(overlays.activeID)
        XCTAssertNil(view.controller, "the surface must be freed synchronously on dismissal, as TerminalCenter.closeSession does — ARC is not the lifecycle boundary here")
        XCTAssertNoThrow(
            try overlays.present(command: "/tmp/next.sh", workingDirectory: "/tmp"),
            "the slot must be free once a review exits, or the first review of a session would be the only one ever possible"
        )
    }

    func testDismissDoesNotReportCompletion() throws {
        let overlays = OverlayCenter(textDelivery: { _, _ in })
        var finished: [String] = []
        overlays.onFinished = { finished.append($0) }

        _ = try overlays.present(command: "/tmp/review.sh", workingDirectory: "/tmp")
        overlays.dismiss()

        XCTAssertNil(overlays.activeID)
        XCTAssertTrue(
            finished.isEmpty,
            "dismiss() is teardown, not completion: reporting it would answer the launcher's socket as though the review had ended normally"
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
            TerminalCenter.sessionEnvVars["AGENTS_CONTROL_SOCK"],
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
