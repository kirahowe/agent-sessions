import XCTest
@testable import Agents

/// Covers `DropTerminalView.shellEscape` only. Deliberately does not
/// instantiate `DropTerminalView` itself or exercise `draggingEntered`/
/// `performDragOperation`: the view spins up real ghostty surface/controller
/// machinery on construction, and `NSDraggingInfo` has no cheap fake — an
/// `NSDraggingInfo` conformance can't be synthesized without a live drag
/// session. The escaper is the actual logic worth locking down here; the two
/// overrides are thin, untestable-in-isolation wiring on top of it.
@MainActor
final class DropTerminalViewTests: XCTestCase {
    func testPlainAbsolutePathIsUnchanged() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/Users/kira/code/file.txt"),
            "/Users/kira/code/file.txt"
        )
    }

    func testSpacesAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/my file.pdf"),
            "/tmp/my\\ file.pdf"
        )
    }

    func testDollarSignIsBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/$file.txt"),
            "/tmp/\\$file.txt"
        )
    }

    func testBacktickIsBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/`file`.txt"),
            "/tmp/\\`file\\`.txt"
        )
    }

    func testSingleQuoteIsBackslashEscapedWhenNoControlCharactersArePresent() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/it's.txt"),
            "/tmp/it\\'s.txt"
        )
    }

    func testDoubleQuoteIsBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/\"quoted\".txt"),
            "/tmp/\\\"quoted\\\".txt"
        )
    }

    func testParenthesesAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/(1).txt"),
            "/tmp/\\(1\\).txt"
        )
    }

    func testAmpersandAndSemicolonAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/a&b;c.txt"),
            "/tmp/a\\&b\\;c.txt"
        )
    }

    func testGlobCharactersAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/a*b?c[d]e.txt"),
            "/tmp/a\\*b\\?c\\[d\\]e.txt"
        )
    }

    func testRedirectionAndPipeCharactersAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/a<b>c|d.txt"),
            "/tmp/a\\<b\\>c\\|d.txt"
        )
    }

    func testTildeHashBangBracesAndBackslashAreBackslashEscaped() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/~a#b!c{d}e\\f.txt"),
            "/tmp/\\~a\\#b\\!c\\{d\\}e\\\\f.txt"
        )
    }

    func testNonASCIIPathIsUnchanged() {
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/résumé.txt"),
            "/tmp/résumé.txt"
        )
    }

    func testNewlineAloneUsesSingleQuoteForm() {
        // Backslash-escaping can't represent a raw newline (backslash-
        // newline is a shell line continuation, not an escaped character),
        // so a control character forces the single-quote fallback instead
        // of the usual backslash-per-character loop.
        XCTAssertEqual(
            DropTerminalView.shellEscape("/tmp/line1\nline2.txt"),
            "'/tmp/line1\nline2.txt'"
        )
    }

    func testNewlineAndEmbeddedQuoteRoundTripTheQuoteEscape() {
        let escaped = DropTerminalView.shellEscape("/tmp/weird\nname's.txt")
        XCTAssertTrue(escaped.hasPrefix("'") && escaped.hasSuffix("'"))
        XCTAssertTrue(
            escaped.contains("'\\''"),
            "an embedded single quote must be closed out of the surrounding quotes, escaped, then reopened"
        )
        XCTAssertTrue(
            escaped.contains("\n"),
            "single-quote wrapping preserves the newline verbatim instead of stripping or escaping it"
        )
    }
}
