import AppKit
import XCTest
@testable import Agents

/// Exercises `KeyboardPopUpButton` directly, without an alert or a modal
/// loop. See `DialogsTests.testPromptNewWorkspaceIsKeyboardNavigable` for
/// the integration-level check that it behaves this way inside the real
/// New Workspace dialog.
@MainActor
final class KeyboardPopUpButtonTests: XCTestCase {
    /// Captures whether/how many times the button's action fired.
    private final class ActionSpy: NSObject {
        private(set) var count = 0
        @objc func fire(_ sender: Any?) { count += 1 }
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
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

    private var downArrow: NSEvent { key("\u{F701}", keyCode: 125) }
    private var upArrow: NSEvent { key("\u{F700}", keyCode: 126) }

    private func makeButton(titles: [String]) -> KeyboardPopUpButton {
        let button = KeyboardPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24), pullsDown: false)
        button.addItems(withTitles: titles)
        return button
    }

    private func attachSpy(to button: KeyboardPopUpButton) -> ActionSpy {
        let spy = ActionSpy()
        button.target = spy
        button.action = #selector(ActionSpy.fire(_:))
        return spy
    }

    /// A stock NSPopUpButton's `canBecomeKeyView` is false unless the
    /// system-wide Full Keyboard Access setting is on — a machine-dependent
    /// setting this suite can't control — so there is no equivalent
    /// assertion made against the stock class here; the override on
    /// `KeyboardPopUpButton` is what is under test.
    func testIsAKeyViewWithoutFullKeyboardAccess() {
        let button = makeButton(titles: ["a", "b"])

        XCTAssertTrue(button.acceptsFirstResponder, "an enabled button must accept first responder without Full Keyboard Access")
        XCTAssertTrue(button.canBecomeKeyView, "an enabled button must join the key view loop without Full Keyboard Access")

        button.isEnabled = false
        XCTAssertFalse(button.acceptsFirstResponder, "a disabled button must not accept first responder")
        XCTAssertFalse(button.canBecomeKeyView, "a disabled button must not join the key view loop")
    }

    /// The core behavior: plain arrow keys step the selection one item at a
    /// time and clamp at either end instead of wrapping, firing the action
    /// only on an actual change.
    func testArrowKeysStepSelectionAndClampAtTheEnds() {
        let button = makeButton(titles: ["a", "b", "c"])
        let spy = attachSpy(to: button)
        button.selectItem(at: 0)

        button.keyDown(with: downArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 1)
        XCTAssertEqual(spy.count, 1)

        button.keyDown(with: downArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 2)
        XCTAssertEqual(spy.count, 2)

        button.keyDown(with: downArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 2, "selection must clamp at the last item, not wrap")
        XCTAssertEqual(spy.count, 2, "clamping at the end must not fire the action")

        button.keyDown(with: upArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 1)
        XCTAssertEqual(spy.count, 3)

        button.keyDown(with: upArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 0)
        XCTAssertEqual(spy.count, 4)

        button.keyDown(with: upArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 0, "selection must clamp at the first item, not wrap")
        XCTAssertEqual(spy.count, 4, "clamping at the start must not fire the action")
    }

    /// Disabled items and separators aren't selectable choices, so arrowing
    /// must skip over them the same way arrowing through the open menu
    /// would.
    func testArrowKeysSkipDisabledItemsAndSeparators() {
        let button = makeButton(titles: [])
        button.addItem(withTitle: "a")
        let disabled = NSMenuItem(title: "b", action: nil, keyEquivalent: "")
        disabled.isEnabled = false
        button.menu?.addItem(disabled)
        button.menu?.addItem(.separator())
        button.addItem(withTitle: "c")
        XCTAssertEqual(button.itemArray.count, 4, "expected a, disabled b, a separator, and c")

        let spy = attachSpy(to: button)
        button.selectItem(at: 0)

        button.keyDown(with: downArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 3, "must skip the disabled item and the separator")
        XCTAssertEqual(spy.count, 1)

        button.keyDown(with: upArrow)
        XCTAssertEqual(button.indexOfSelectedItem, 0)
        XCTAssertEqual(spy.count, 2)
    }

    /// An arrow with a modifier held falls through to `super.keyDown`,
    /// which for a pop-up button has no visible effect — it does not open
    /// the menu — so this cannot hang the test the way sending Space would.
    func testModifiedArrowKeysDoNotStepSelection() {
        let button = makeButton(titles: ["a", "b", "c"])
        let spy = attachSpy(to: button)
        button.selectItem(at: 0)

        button.keyDown(with: key("\u{F701}", keyCode: 125, modifiers: [.command]))
        XCTAssertEqual(button.indexOfSelectedItem, 0, "a Command-modified arrow must not step the selection")

        button.keyDown(with: key("\u{F701}", keyCode: 125, modifiers: [.shift]))
        XCTAssertEqual(button.indexOfSelectedItem, 0, "a Shift-modified arrow must not step the selection")
        XCTAssertEqual(spy.count, 0, "no modified arrow may fire the action")
    }
}
