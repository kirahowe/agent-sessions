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
    private var receivedAgentEvents: [(id: String, event: AgentSessionEvent)] = []

    override func setUp() async throws {
        try await super.setUp()
        let center = TerminalCenter()
        center.onSessionSignal = { [weak self] id, _, signal in
            self?.received.append((id, signal))
        }
        center.onAgentSessionEvent = { [weak self] id, event, _ in
            self?.receivedAgentEvents.append((id, event))
        }
        self.center = center
        proxy = SessionDelegateProxy(sessionID: sessionID, paneID: UUID(), center: center)
    }

    override func tearDown() async throws {
        proxy = nil
        center = nil
        received = []
        receivedAgentEvents = []
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

    // MARK: - 4

    func test04_bellForwardsAsBellSignal() {
        proxy.terminalDidRingBell()

        XCTAssertEqual(
            received.first?.signal, .bell,
            "a bare BEL must reach the reducer — this conformance is the app's only subscription to it, and because the package registers delegates by conditional-casting the single delegate object, dropping the conformance would compile cleanly and simply never fire"
        )
    }

    // MARK: - 5

    func test05_progressSetAndIndeterminateForwardAsWorking() {
        proxy.terminalDidReportProgress(state: .set, percent: 42)
        proxy.terminalDidReportProgress(state: .indeterminate, percent: nil)

        XCTAssertEqual(
            received.map(\.signal), [.working, .working],
            "an agent actively reporting progress is demonstrably busy, so both the determinate and indeterminate states must map to .working — mapping either one to a raise instead would light up the sidebar for a session that is visibly getting on with its job"
        )
    }

    // MARK: - 6

    func test06_progressErrorAndPauseForwardAsRaises() {
        proxy.terminalDidReportProgress(state: .error, percent: nil)
        proxy.terminalDidReportProgress(state: .pause, percent: 60)

        XCTAssertEqual(
            received.map(\.signal), [.bell, .bell],
            "error and pause both mean the run stopped short and is sitting there — they must raise, at bell fidelity, rather than being treated as more work in progress"
        )
    }

    // MARK: - 7

    func test07_progressRemoveIsDroppedEntirely() {
        proxy.terminalDidReportProgress(state: .remove, percent: nil)

        XCTAssertTrue(
            received.isEmpty,
            "a progress bar being torn down is equally consistent with 'finished' and 'gave up', so it must produce no signal at all — mapping it to a raise would cry wolf on every abandoned task, and mapping it to .working would clear a genuine indicator the moment an unrelated progress bar disappeared"
        )
    }

    // MARK: - 8

    /// `percent` is not part of any signal — nothing in this design renders
    /// progress — so the same state must produce the same signal whatever
    /// number rides along with it.
    func test08_progressPercentDoesNotAffectTheSignal() {
        for percent in [nil, 0, 50, 100] as [Int?] {
            received = []
            proxy.terminalDidReportProgress(state: .set, percent: percent)
            XCTAssertEqual(received.map(\.signal), [.working], "progress percent \(String(describing: percent)) must not change which signal a .set report produces")
        }
    }

    // MARK: - Session-resume protocol (Warp CLI-agent title and the app's own hook title)

    func testValidWarpTitleOmpNotificationUsesDistinctCallbackAndNeverBecomesAttentionSignal() {
        proxy.terminalDidRequestDesktopNotification(
            title: AgentSessionEvent.warpNotificationTitle,
            body: #"{"event":"prompt_submit","v":1,"agent":"omp","session_id":"omp-123","query":"Fix it"}"#
        )

        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(receivedAgentEvents.map(\.id), [sessionID])
        XCTAssertEqual(receivedAgentEvents.first?.event.agent, "omp")
        XCTAssertEqual(receivedAgentEvents.first?.event.sessionID, "omp-123")
        XCTAssertEqual(receivedAgentEvents.first?.event.query, "Fix it")
    }

    func testMalformedOrUnsupportedWarpNotificationIsConsumed() {
        for body in [
            "not json",
            #"{"event":"stop","v":2,"agent":"omp","session_id":"omp-123"}"#,
            #"{"event":"stop","v":1,"agent":"  ","session_id":"omp-123"}"#,
        ] {
            proxy.terminalDidRequestDesktopNotification(
                title: AgentSessionEvent.warpNotificationTitle,
                body: body
            )
        }

        XCTAssertTrue(received.isEmpty)
        XCTAssertTrue(receivedAgentEvents.isEmpty)
    }

    func testValidHookTitleClaudeNotificationReachesAgentEventCallbackAndRaisesNoAttention() {
        proxy.terminalDidRequestDesktopNotification(
            title: AgentSessionEvent.hookNotificationTitle,
            body: #"{"event":"session_start","v":1,"agent":"claude","session_id":"c-1"}"#
        )

        XCTAssertTrue(
            received.isEmpty,
            "hooks/agents-status.sh will emit agents:session on every prompt — if this ever leaked to the attention path it would raise a bogus gold dot each time"
        )
        XCTAssertEqual(receivedAgentEvents.map(\.id), [sessionID])
        XCTAssertEqual(receivedAgentEvents.first?.event.agent, "claude")
        XCTAssertEqual(receivedAgentEvents.first?.event.sessionID, "c-1")
    }

    func testMalformedHookTitleNotificationIsConsumedNotClassified() {
        for body in [
            "not json",
            #"{"event":"stop","v":1,"agent":"","session_id":"c-1"}"#,
        ] {
            proxy.terminalDidRequestDesktopNotification(
                title: AgentSessionEvent.hookNotificationTitle,
                body: body
            )
        }

        XCTAssertTrue(
            received.isEmpty,
            "a malformed agents:session envelope must never fall through to keyword classification — the hook's own title must never accidentally become a free-text attention signal"
        )
        XCTAssertTrue(receivedAgentEvents.isEmpty)
    }

    func testAgentsStatusNotificationStillProducesStructuredSignal() {
        // Regression guard: gating on isSessionNotification(title:) must not
        // swallow the unrelated agents:status protocol that AttentionSignal
        // relies on.
        proxy.terminalDidRequestDesktopNotification(title: "agents:status", body: "blocked")

        XCTAssertEqual(received.map(\.signal), [.structured(.set(.blocked))])
        XCTAssertTrue(receivedAgentEvents.isEmpty)
    }
}
