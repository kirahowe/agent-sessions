import GhosttyTerminal
import XCTest
@testable import Agents

/// `SessionDelegateProxy` is the translation layer between libghostty's
/// delegate callbacks and `AttentionSignal` — the one place a terminal event
/// becomes something the reducer can reason about. It decides nothing itself,
/// so what these tests pin is exactly that: which signal case each callback
/// produces, and that it produces one at all.
///
/// No real terminal machinery is involved. The proxy only needs a
/// `TerminalCenter` to forward to, and `TerminalCenter.onSessionSignal` is a
/// plain callback, so a bare center with a recording closure is the whole
/// fixture. (A missing conformance would compile fine and silently never
/// fire — the package registers specialized delegates by conditional-casting
/// the single delegate object — which is what makes callback-level coverage
/// here worth having rather than redundant with the reducer's own tests.)
@MainActor
final class SessionDelegateProxyTests: XCTestCase {
    private let sessionID = "session-under-test"

    /// Held as a property, not a local in `setUp`, because
    /// `SessionDelegateProxy.center` is a WEAK reference — in production the
    /// center owns every proxy and outlives them all. A fixture that let the
    /// center go out of scope would record nothing at all, and every
    /// assertion below would fail for a reason that has nothing to do with
    /// the code under test.
    private var center: TerminalCenter!
    private var proxy: SessionDelegateProxy!
    private var received: [(id: String, signal: AttentionSignal)] = []

    override func setUp() async throws {
        try await super.setUp()
        let center = TerminalCenter()
        center.onSessionSignal = { [weak self] id, signal in
            self?.received.append((id, signal))
        }
        self.center = center
        proxy = SessionDelegateProxy(sessionID: sessionID, center: center)
    }

    override func tearDown() async throws {
        proxy = nil
        center = nil
        received = []
        try await super.tearDown()
    }

    // MARK: - 1

    func test01_structuredStatusNotificationForwardsAsStructuredSignal() {
        proxy.terminalDidRequestDesktopNotification(title: "agents:status", body: "blocked")

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.id, sessionID, "the signal must carry the session id this proxy was created for — neither delegate callback carries the sender's identity, so a proxy forwarding the wrong id would light up an unrelated session's row")
        XCTAssertEqual(
            received.first?.signal, .structured(.set(.blocked)),
            "an agents:status payload must forward as .structured, not as free text — the structured case is what latches the session onto the high-fidelity path, and misrouting it would leave a hooked session permanently at the mercy of keyword classification"
        )
    }

    // MARK: - 2

    func test02_freeTextNotificationForwardsAsNotificationSignal() {
        proxy.terminalDidRequestDesktopNotification(title: "Claude Code", body: "Claude needs your permission to use Bash")

        XCTAssertEqual(
            received.first?.signal,
            .notification(title: "Claude Code", body: "Claude needs your permission to use Bash"),
            "a notification that isn't the agents:status protocol must be forwarded verbatim for the reducer to classify — this is the path that lights up every agent with no hook installed, and dropping it here (as this proxy used to) is invisible from the outside: the app simply looks like it lacks the feature"
        )
    }

    // MARK: - 3

    func test03_freeTextIsForwardedUnmodifiedSoTheClassifierSeesTheRealText() {
        proxy.terminalDidRequestDesktopNotification(title: "  Gemini CLI  ", body: "Task\ncomplete")

        XCTAssertEqual(
            received.first?.signal,
            .notification(title: "  Gemini CLI  ", body: "Task\ncomplete"),
            "the proxy must not trim, normalise or otherwise pre-chew the text — all interpretation belongs to AttentionClassifier, and a proxy that quietly cleaned up the input would put two different normalisation rules in play with only one of them tested"
        )
    }
}
