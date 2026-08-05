import AppKit
import XCTest
@testable import Agents

@MainActor
final class KeymapTests: XCTestCase {
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

    func test_noDuplicateBindings() {
        var seen: Set<Shortcut> = []
        for (action, shortcut) in Keymap.standard {
            let (inserted, _) = seen.insert(shortcut)
            XCTAssertTrue(inserted, "Keyboard conflict introduced: \(action) reuses a shortcut already bound to another action (\(shortcut)).")
        }
    }

    func test_commandT_mapsToNewSession() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "t", modifiers: [.command])), .newSession)
    }

    func test_commandW_mapsToCloseSession() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "w", modifiers: [.command])), .closeSession)
    }

    // Uppercase "R" because that is what a real ⇧⌘R keydown carries — the
    // shift modifier uppercases charactersIgnoringModifiers. Matching
    // lowercases both sides, so this also pins that behavior.
    func test_shiftCommandR_mapsToRenameSession() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "R", modifiers: [.command, .shift])), .renameSession)
    }

    func test_shiftCommandW_mapsToCloseWindowNotCloseSession() {
        let action = Keymap.action(for: keyEvent(characters: "W", modifiers: [.command, .shift]))
        XCTAssertEqual(action, .closeWindow)
        XCTAssertNotEqual(action, .closeSession)
    }

    func test_optionCommandDownArrow_mapsToNextSession() {
        // Adjust characters/keyCode here if event.specialKey needs the
        // function-key scalar instead — see the note in Shortcut.matches.
        let event = keyEvent(characters: "\u{F701}", modifiers: [.command, .option], keyCode: 125)
        XCTAssertEqual(Keymap.action(for: event), .nextSession)
    }

    func test_command3_mapsToSelectSessionIndex2() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "3", modifiers: [.command])), .selectSession(2))
    }

    func test_plainT_noModifiers_isNil() {
        XCTAssertNil(Keymap.action(for: keyEvent(characters: "t", modifiers: [])))
    }

    func test_controlCommandT_extraModifier_isNil() {
        XCTAssertNil(Keymap.action(for: keyEvent(characters: "t", modifiers: [.command, .control])))
    }

    func test_commandN_mapsToNewWorkspace() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "n", modifiers: [.command])), .newWorkspace)
    }

    func test_shiftCommandSlash_mapsToShowShortcutHelp() {
        XCTAssertEqual(Keymap.action(for: keyEvent(characters: "?", modifiers: [.command, .shift])), .showShortcutHelp)
    }

    func test_everyKeymapActionHasNonEmptyHelpTitle() {
        for action in Keymap.standard.keys {
            XCTAssertFalse(action.helpTitle.isEmpty, "\(action) is missing a non-empty helpTitle for the shortcut-help sheet")
        }
    }
}
