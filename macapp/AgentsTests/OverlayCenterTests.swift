import AppKit
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
    /// differ *only* by bundle id — reachable independently. If this ever
    /// collapsed to a fixed name, a review fired from one build could open in
    /// the other, which is precisely the failure a URL scheme was rejected for.
    func testControlSocketPathIsScopedToTheBundle() {
        let path = ControlServer.socketPath
        let bundleID = Bundle(for: OverlayCenterTests.self).bundleIdentifier
        XCTAssertTrue(path.hasSuffix(".control.sock"), "unexpected socket path: \(path)")
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
