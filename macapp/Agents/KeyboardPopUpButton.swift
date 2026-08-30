import AppKit

/// An `NSPopUpButton` that is a full keyboard citizen without Full Keyboard
/// Access: it takes part in the window's Tab loop the way a text field
/// does, and ↑/↓ step through its items while it has focus. Space still
/// opens the menu, where the arrow keys, Return and Escape behave as they
/// do in any menu.
///
/// A stock NSPopUpButton only becomes a key view when the system-wide
/// "keyboard navigation" setting is on — off by default — so in a form it
/// silently drops out of the Tab order, and the arrow keys do nothing until
/// the menu is opened.
final class KeyboardPopUpButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }

    /// NSButton gates this on `NSApp.isFullKeyboardAccessEnabled` even when
    /// `acceptsFirstResponder` is true. This is the override that actually
    /// puts the control into the window's automatic key view loop.
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func keyDown(with event: NSEvent) {
        let hasModifiers = !event.modifierFlags
            .intersection([.command, .shift, .option, .control])
            .isEmpty
        switch event.specialKey {
        case .downArrow? where !hasModifiers:
            stepSelection(by: 1)
        case .upArrow? where !hasModifiers:
            stepSelection(by: -1)
        default:
            super.keyDown(with: event)
        }
    }

    /// Moves the selection one selectable item in `direction`, skipping
    /// disabled items and separators, and stops at either end rather than
    /// wrapping — the same as arrowing through the open menu. Fires the
    /// action on a change, as a mouse pick would.
    private func stepSelection(by direction: Int) {
        var index = indexOfSelectedItem
        repeat {
            index += direction
            guard itemArray.indices.contains(index) else { return }
        } while !itemArray[index].isEnabled || itemArray[index].isSeparatorItem
        selectItem(at: index)
        sendAction(action, to: target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
