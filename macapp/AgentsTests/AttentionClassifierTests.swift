import XCTest
@testable import Agents

/// Coverage for `AttentionClassifier.classify`: each cue set individually
/// (via the classifier's own `blockedCues`/`yourTurnCues` statics, so these
/// tests can never drift out of sync with what the classifier actually
/// checks), precedence between the two sets, the unmatched fallback,
/// case/whitespace tolerance, matching across the title/body join, and a
/// handful of real notification strings agents in the wild actually emit.
final class AttentionClassifierTests: XCTestCase {

    // MARK: - 1

    func test01_everyBlockedCueClassifiesBlocked() {
        for cue in AttentionClassifier.blockedCues {
            let result = AttentionClassifier.classify(title: "", body: cue)
            XCTAssertEqual(result, .blocked, "the blocked cue \"\(cue)\" must classify as .blocked — if this regresses, a real permission-prompt notification using this wording would show the gold dot instead of red, and a user who trusts the colour would walk away from an agent that's actually stuck")
        }
    }

    // MARK: - 2

    func test02_everyYourTurnCueClassifiesYourTurn() {
        for cue in AttentionClassifier.yourTurnCues {
            let result = AttentionClassifier.classify(title: "", body: cue)
            XCTAssertEqual(result, .yourTurn, "the your-turn cue \"\(cue)\" must classify as .yourTurn")
        }
    }

    // MARK: - 3

    func test03_cuePrecedenceBlockedWinsWhenBothPresent() {
        let result = AttentionClassifier.classify(title: "Claude Code", body: "finished waiting, needs your permission to continue")

        XCTAssertEqual(result, .blocked, "when a notification's text matches cues from both lists — plausible, e.g. a permission prompt whose body also happens to say \"waiting\" — blocked must win; defaulting to the less urgent state here would bury a real permission prompt under the calmer gold dot")
    }

    // MARK: - 4

    func test04_unmatchedTextFallsBackToYourTurn() {
        // Deliberately NOT "Build finished with 3 warnings" — that string
        // actually contains the your-turn cue "finished" and would pass
        // for the wrong reason. These two are checked against every cue in
        // both lists to make sure they're genuinely unmatched.
        for text in ["npm install", "hello"] {
            for cue in AttentionClassifier.blockedCues + AttentionClassifier.yourTurnCues {
                XCTAssertFalse(text.contains(cue), "test fixture \"\(text)\" unexpectedly contains cue \"\(cue)\" — pick different unmatched fixture text")
            }
            let result = AttentionClassifier.classify(title: "", body: text)
            XCTAssertEqual(result, .yourTurn, "text matching no known cue at all must still fall back to .yourTurn, never .blocked — a notification firing at all means something wants the user, and .yourTurn is the safe direction to guess wrong in")
        }
    }

    // MARK: - 5

    func test05_caseInsensitivityUpperAndMixedCase() {
        XCTAssertEqual(
            AttentionClassifier.classify(title: "", body: "NEEDS YOUR PERMISSION"), .blocked,
            "an all-caps permission notification must still classify as blocked — matching is defined over lowercased text specifically so agents that shout their notifications don't silently fall through every cue"
        )
        XCTAssertEqual(
            AttentionClassifier.classify(title: "", body: "Awaiting Your Response"), .yourTurn,
            "mixed-case notification text (the common case — most agents title-case their own notifications) must still match its cue"
        )
    }

    // MARK: - 6

    func test06_leadingTrailingWhitespaceTolerance() {
        let result = AttentionClassifier.classify(title: "  \n", body: "  needs your approval  \t")

        XCTAssertEqual(result, .blocked, "surrounding whitespace/newlines around the actual notification text must not stop cue matching — libghostty's title/body fields are passed through largely as-is, so trimming has to happen here rather than being assumed away upstream")
    }

    // MARK: - 7

    func test07_cueMatchedInTitleOnly() {
        let result = AttentionClassifier.classify(title: "Approval required", body: "")

        XCTAssertEqual(result, .blocked, "a cue appearing only in the title (the common shape for OSC 777, which has a real title field) must still be found — classification checks the combined title+body text, not the body alone")
    }

    // MARK: - 8

    func test08_cueMatchedInBodyOnly() {
        let result = AttentionClassifier.classify(title: "Claude Code", body: "Claude is idle")

        XCTAssertEqual(result, .yourTurn, "a cue appearing only in the body (the common shape for agents that leave the title generic, e.g. just the app name) must still be found")
    }

    // MARK: - 9

    func test09_cueSplitAcrossTheTitleBodyJoinBoundaryStillMatches() {
        // Neither field contains "needs your input" on its own — it only
        // exists once title and body are joined with a space, which proves
        // classification runs over `title + " " + body`, not each field
        // checked independently.
        let result = AttentionClassifier.classify(title: "Reminder: needs your", body: "input before you can continue")

        XCTAssertEqual(result, .yourTurn, "a cue phrase split across the title/body boundary by the terminal must still be found once the two are joined — checking title and body as two independent strings would miss this and any classifier that special-cased one field over the other would have the same gap")
    }

    // MARK: - 9b

    func test09b_multiWordCueBrokenByANewlineStillMatches() {
        let result = AttentionClassifier.classify(title: "Claude Code", body: "Claude\nneeds  your\n input")

        XCTAssertEqual(result, .yourTurn, "notification bodies arrive wrapped and newline-broken, so a multi-word cue split by a line break must still match — matching on the raw string would miss text a human reads as containing the phrase verbatim, and every multi-word cue in either list would be one soft wrap away from silently never firing")
    }

    // MARK: - 10

    /// Captured shape of what Claude Code actually emits with
    /// `preferredNotifChannel` set to a terminal channel — see the design
    /// doc's "Verification" section, which calls for testing against real
    /// captured text rather than invented strings.
    func test10_realisticClaudeCodePermissionNotificationClassifiesBlocked() {
        let result = AttentionClassifier.classify(title: "Claude Code", body: "Claude needs your permission to use Bash")

        XCTAssertEqual(result, .blocked, "the real notification Claude Code sends for a tool permission prompt must classify as blocked — this is the single most common real-world case the whole classifier exists for")
    }

    // MARK: - 11

    func test11_realisticClaudeCodeWaitingNotificationClassifiesYourTurn() {
        let result = AttentionClassifier.classify(title: "Claude Code", body: "Claude is waiting for your input")

        XCTAssertEqual(result, .yourTurn, "the real notification Claude Code sends at the end of a turn must classify as your-turn")
    }

    // MARK: - 12

    /// Gemini CLI emits OSC notifications on turn completion (see the design
    /// doc's platform-facts section). "Task complete" matches the
    /// your-turn cue "complete" directly — it doesn't exercise the
    /// fallback (see `test04` for that), but it does confirm the classifier
    /// works for an agent that never speaks the structured protocol at all.
    func test12_realisticGeminiCliTurnCompletionNotificationClassifiesYourTurn() {
        let result = AttentionClassifier.classify(title: "Gemini CLI", body: "Task complete")

        XCTAssertEqual(result, .yourTurn, "a Gemini CLI turn-completion notification must raise the gold dot even though Gemini never speaks the structured agents:status protocol — this is the classifier's entire reason for existing")
    }
}
