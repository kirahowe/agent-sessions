import AppKit
import XCTest
@testable import Agents

/// `ShortcutRouter.handle(_:)` is internal (not private) specifically so
/// these tests can exercise the consume/pass-through decision directly via
/// `@testable import Agents`, without a real global NSEvent monitor or real
/// NSApp modal state.
@MainActor
final class ShortcutRouterTests: XCTestCase {
    // Small private duplicate of KeymapTests' construction helper — not
    // worth sharing for just these two test files.
    private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func test_matchedEventAndPerformTrue_isConsumedAndDispatchesCorrectAction() {
        var performed: [AppAction] = []
        let router = ShortcutRouter(
            perform: { action in
                performed.append(action)
                return true
            },
            isModalActive: { false }
        )

        let event = keyEvent(characters: "t", modifiers: [.command])
        let result = router.handle(event)

        XCTAssertNil(result, "a handled action must consume the event")
        XCTAssertEqual(performed, [.newSession])
    }

    func test_matchedEventAndPerformFalse_passesEventThrough() {
        let router = ShortcutRouter(
            perform: { _ in false },
            isModalActive: { false }
        )

        let event = keyEvent(characters: "t", modifiers: [.command])
        let result = router.handle(event)

        XCTAssertNotNil(result, "an action reported not-currently-valid must let the system handle the event normally")
    }

    func test_modalActive_shortCircuitsBeforePerformIsCalled() {
        var performCallCount = 0
        let router = ShortcutRouter(
            perform: { _ in
                performCallCount += 1
                return true
            },
            isModalActive: { true }
        )

        let event = keyEvent(characters: "t", modifiers: [.command])
        let result = router.handle(event)

        XCTAssertNotNil(result, "a modal alert/panel owns the keyboard, so the event must pass through")
        XCTAssertEqual(performCallCount, 0, "perform must never be called while a modal is active")
    }

    func test_plainKeydownWithNoModifiers_isNotDispatched() {
        var performCallCount = 0
        let router = ShortcutRouter(
            perform: { _ in
                performCallCount += 1
                return true
            },
            isModalActive: { false }
        )

        let event = keyEvent(characters: "t", modifiers: [])
        let result = router.handle(event)

        XCTAssertNotNil(result, "plain typing with no command modifier must pass through")
        XCTAssertEqual(performCallCount, 0, "the fast-path must bail before ever reaching Keymap/perform")
    }
}
