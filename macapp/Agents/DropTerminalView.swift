import AppKit
import Foundation
import GhosttyTerminal

/// A `TerminalView` subclass that adds Finder drag-and-drop, iTerm2-style.
///
/// libghostty-spm ships no drag-and-drop support for AppKit — dropping a
/// file onto a bare `TerminalView` does nothing. `AppTerminalView+PublicInput.swift`
/// does give us `paste(text:)`, the public paste path: text goes to the pty
/// the way a paste does (bracketed, for a program that asked for that), with
/// no synthetic keystrokes and no IME or dead-key interaction. That's exactly
/// what a drop wants. This class exists solely to wire Finder's drag
/// pasteboard to that write path, escaping each dropped path the way a shell
/// would expect it typed.
@MainActor
final class DropTerminalView: TerminalView {
    /// Restricts pasteboard reads to genuine file URLs (as opposed to
    /// arbitrary strings that merely parse as a `file:` URL).
    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    /// `AppTerminalView.init?(coder:)` is `@available(*, unavailable)` and
    /// unconditionally `fatalError`s (this view is never loaded from a nib).
    /// Because it's `unavailable`, `super.init(coder:)` cannot even be
    /// referenced from a subclass — the compiler rejects the call outright —
    /// so this override can't follow the usual "call super, then configure"
    /// shape the way `init(frame:)` above does. Instead it just mirrors the
    /// superclass's own refusal directly. Registering for dragged types here
    /// would be dead code anyway, since this initializer never returns.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: Self.fileURLReadingOptions
        ) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: Self.fileURLReadingOptions
            ) as? [URL],
            !urls.isEmpty
        else {
            return false
        }

        // A trailing space lets the user keep typing an argument right
        // after the paste (e.g. drop a file onto `cat `, then type more),
        // matching the iTerm2 convention this feature is modeled on.
        let pasted = urls.map { Self.shellEscape($0.path) }.joined(separator: " ")
        paste(text: pasted + " ")
        return true
    }

    /// Characters that never need escaping in a POSIX shell word: ASCII
    /// letters/digits plus the punctuation that shows up routinely in file
    /// paths. Everything else is either backslash-escaped or, for control
    /// characters, forces the single-quote fallback below.
    private static let safeASCII = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+:@%=,")

    /// Non-ASCII scalars (é, 日, emoji, ...) are always safe too — shells
    /// treat them as ordinary word characters, so escaping them would only
    /// add noise (or, worse, a spurious backslash a naive reader might
    /// mistake for meaningful).
    private static func isSafe(_ scalar: Unicode.Scalar) -> Bool {
        safeASCII.contains(scalar) || !scalar.isASCII
    }

    /// Shell-escapes a single dropped path, iTerm2-style: unchanged when
    /// already safe, backslash-escaped for the common case (spaces, shell
    /// metacharacters), and single-quoted only when backslash-escaping
    /// can't do the job.
    static func shellEscape(_ path: String) -> String {
        if path.unicodeScalars.allSatisfy(isSafe) {
            return path
        }

        // Backslash-escaping cannot represent a raw newline: `\` followed
        // by a literal newline is a shell line continuation, not an escaped
        // character, so there is no backslash sequence that means "keep
        // this newline as data." Any control character (not just newline)
        // forces the single-quote fallback instead, since everything
        // between single quotes is literal with one exception — a single
        // quote can't appear inside its own quoting, so each embedded `'`
        // is closed out of the quoted string, escaped, and the string
        // reopened: `'\''`.
        let breaksBackslashEscaping = CharacterSet.controlCharacters.union(.newlines)
        if path.unicodeScalars.contains(where: { breaksBackslashEscaping.contains($0) }) {
            let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'" + quoted + "'"
        }

        var escaped = ""
        for scalar in path.unicodeScalars {
            if isSafe(scalar) {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped += "\\"
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}
