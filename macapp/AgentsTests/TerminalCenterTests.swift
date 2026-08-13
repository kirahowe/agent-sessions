import GhosttyTerminal
import XCTest
@testable import Agents

/// `TerminalCenter.terminalConfiguration` is the ghostty configuration
/// applied to every spawned session's shell. It used to be built inline as
/// an anonymous closure passed straight to `TerminalController`, which made
/// it impossible to assert on. Now that it's a static `TerminalConfiguration`
/// value, these tests pin its rendered output directly.
///
/// `TerminalConfigCommand.renderedLine` (GhosttyTerminal) renders each
/// setting as `"key = value"` — a single space on each side of `=`, no
/// quoting — so assertions below match that exact shape rather than
/// guessing at ghostty.conf syntax.
@MainActor
final class TerminalCenterTests: XCTestCase {
    private var rendered: String { TerminalCenter.terminalConfiguration.rendered }

    func testTermIsXterm256Color() {
        XCTAssertTrue(
            rendered.contains("term = xterm-256color"),
            "term=xterm-256color is missing from the terminal configuration — the package bundles no terminfo, so the default TERM=xterm-ghostty breaks ncurses apps (vim, htop, ...) in every spawned shell"
        )
    }

    func testWindowPaddingXIsSet() {
        XCTAssertTrue(
            rendered.contains("window-padding-x = 10"),
            "window-padding-x=10 is missing from the terminal configuration — terminal content will lose its horizontal breathing room"
        )
    }

    func testWindowPaddingYIsSet() {
        XCTAssertTrue(
            rendered.contains("window-padding-y = 10"),
            "window-padding-y=10 is missing from the terminal configuration — terminal content will lose its vertical breathing room"
        )
    }

    func testCursorColorMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("cursor-color = \(Theme.Terminal.cursorColor)"),
            "cursor-color no longer matches Theme.Terminal.cursorColor — the app has quietly lost its brand cursor colour"
        )
    }

    func testCursorTextMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("cursor-text = \(Theme.Terminal.cursorText)"),
            "cursor-text no longer matches Theme.Terminal.cursorText — the app has quietly lost its brand cursor text colour"
        )
    }

    func testSelectionBackgroundMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("selection-background = \(Theme.Terminal.selectionBackground)"),
            "selection-background no longer matches Theme.Terminal.selectionBackground — the app has quietly lost its brand selection colour"
        )
    }

    func testSelectionForegroundMatchesBrandTheme() {
        XCTAssertTrue(
            rendered.contains("selection-foreground = \(Theme.Terminal.selectionForeground)"),
            "selection-foreground no longer matches Theme.Terminal.selectionForeground — the app has quietly lost its brand selection colour"
        )
    }

    /// `TerminalCenter.sessionEnvVars` is the app's half of its contract with
    /// `hooks/agents-status.sh`: that hook is registered globally in the
    /// user's Claude Code settings (so it also runs for sessions hosted in
    /// iTerm2 and every other terminal), and it refuses to emit its OSC 777
    /// status escape unless it sees a non-empty `AGENTS_APP` in its
    /// environment. If this static ever loses that key — or stops being
    /// passed through to `TerminalSurfaceOptions.envVars` — the hook keeps
    /// running exactly as before but silently exits before writing anything,
    /// which means every session's sidebar status indicator (the gold/red
    /// dot) simply stops updating, with nothing in this app's own logs to
    /// explain why.
    func testSessionEnvVarsStampsAGENTS_APP() {
        let value = TerminalCenter.sessionEnvVars["AGENTS_APP"]
        XCTAssertNotNil(
            value,
            "TerminalCenter.sessionEnvVars is missing AGENTS_APP — hooks/agents-status.sh gates its entire OSC 777 status escape on that variable, so every session's sidebar status indicator would silently stop updating with no error to point at why"
        )
        XCTAssertFalse(
            value?.isEmpty ?? true,
            "TerminalCenter.sessionEnvVars sets AGENTS_APP to an empty string — the hook's guard treats an unset-or-empty value identically, so this would disable every session's sidebar status indicator just as completely as dropping the key entirely"
        )
    }
}
