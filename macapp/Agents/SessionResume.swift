import Foundation

/// Persisted information needed to reconnect a restored terminal row to the
/// agent session it was last running, whichever harness that was. All
/// presentation fields are optional so a valid protocol event can make the
/// session resumable even before the harness publishes a useful terminal
/// title or prompt.
struct SessionResumeMetadata: Codable, Hashable {
    /// Lowercase harness identifier reported by the emitter — "omp",
    /// "claude", "codex", or (in principle) anything else a future hook
    /// chooses to send. Every harness-specific decision (display name,
    /// resume command, title decoration) is a small switch on this string,
    /// and lives entirely in this file — see the extension below.
    var agent: String
    var sessionID: String
    var title: String?
    var prompt: String?
    /// The harness's configuration home when it announced itself —
    /// `CODEX_HOME` for Codex, `CLAUDE_CONFIG_DIR` for Claude Code — if its
    /// environment had one set. A harness keeps its sessions under that
    /// directory, so the same resume command typed into a fresh shell that
    /// lacks the variable looks in the default location and finds nothing;
    /// the command carries the assignment as a prefix instead (see
    /// `resumeCommand`). Nil when the harness ran from its default home, or
    /// announced through a transport with no field for it (OMP's Warp
    /// envelope). Optional so state files written before this field
    /// existed still decode.
    var home: String? = nil
}

/// The small, Foundation-only portion of the session-announcement protocol
/// this app consumes: which harness is running in a pane, under which of
/// its own session ids, and optionally what the user last asked it. It
/// arrives by two transports. OMP speaks Warp's CLI-agent protocol natively
/// — a JSON envelope in an OSC 777 desktop notification under
/// `warpNotificationTitle` — while the app's own hook
/// (`hooks/agents-status.sh`, for Claude Code and Codex) sends the same
/// facts as a `session-event` line over the control socket (see
/// `ControlServer`). Both funnel through `make`, so a session looks the
/// same downstream whichever way it was announced. Unknown JSON fields and
/// event-specific fields other than `query` are deliberately ignored.
struct AgentSessionEvent: Hashable {
    /// Warp's CLI-agent protocol title — OMP emits this natively.
    static let warpNotificationTitle = "warp://cli-agent"
    /// The app's own OSC title. The bundled hook no longer emits it — Ghostty
    /// throttles desktop notifications app-wide (one per second, identical
    /// content suppressed for five), which silently dropped the hook's
    /// announcement every time it followed a status escape — but the form
    /// stays accepted for any other emitter that adopted it.
    static let hookNotificationTitle = "agents:session"

    static func isSessionNotification(title: String) -> Bool {
        title == warpNotificationTitle || title == hookNotificationTitle
    }

    /// Lowercase harness identifier reported by the emitter. Any non-blank
    /// value is accepted here — see `SessionResumeMetadata` for where an
    /// unrecognized agent degrades gracefully rather than being rejected.
    let agent: String
    /// The emitter's own event name, in whatever spelling it uses (OMP's
    /// "prompt_submit", the hook's verbatim "UserPromptSubmit"). Informational
    /// only — nothing in the app switches on it.
    let name: String
    let sessionID: String
    let query: String?
    /// The harness's configuration home, forwarded by the hook — see
    /// `SessionResumeMetadata.home`. The OSC envelopes have no field for it.
    let home: String?

    init(agent: String, name: String, sessionID: String, query: String?, home: String? = nil) {
        self.agent = agent
        self.name = name
        self.sessionID = sessionID
        self.query = query
        self.home = home
    }

    private struct WireEnvelope: Decodable {
        let event: String
        let v: Int
        let agent: String
        let sessionID: String
        let query: String?

        private enum CodingKeys: String, CodingKey {
            case event, v, agent, query
            case sessionID = "session_id"
        }
    }

    /// The one normalization every announcement passes through, whichever
    /// transport carried it: the harness identifier is compared lowercase
    /// everywhere downstream, ids and names are trimmed, and the prompt
    /// preview is collapsed to one printable line capped at 200 characters
    /// — a bound the OSC transport needs (terminals drop oversized escapes)
    /// and the socket keeps so the banner heading it may become stays a
    /// heading. A blank home is no home. Nil for a blank agent, event name,
    /// or session id: an empty harness identifier would silently fail every
    /// downstream switch rather than error anywhere.
    static func make(
        agent: String, name: String, sessionID: String, query: String?, home: String? = nil
    ) -> AgentSessionEvent? {
        let agent = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty, !name.isEmpty, !sessionID.isEmpty else { return nil }

        let query = query.flatMap { query -> String? in
            let preview = terminalSafeSingleLine(query)
            guard !preview.isEmpty else { return nil }
            return String(preview.prefix(200))
        }
        let home = home.flatMap { home -> String? in
            let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return AgentSessionEvent(agent: agent, name: name, sessionID: sessionID, query: query, home: home)
    }

    static func parseNotification(title: String, body: String) -> AgentSessionEvent? {
        guard isSessionNotification(title: title),
              let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              envelope.v == 1
        else { return nil }
        return make(
            agent: envelope.agent, name: envelope.event,
            sessionID: envelope.sessionID, query: envelope.query
        )
    }
}

extension SessionResumeMetadata {
    private static let ompSpinnerCharacters: Set<Character> = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    /// Claude Code's own status glyphs: `✳` while idle, one of the four
    /// quarter-circle spinner frames while working.
    private static let claudeGlyphs: Set<Character> = Set("✳◐◓◑◒")

    /// Human-readable harness name for resume-hint text. An agent this
    /// table doesn't recognize falls back to its raw identifier so a future
    /// harness's hook still prints something sensible before this table
    /// learns its proper name.
    static func displayName(agent: String) -> String {
        switch agent {
        case "omp": return "OMP"
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return agent
        }
    }

    /// The shell command that resumes a harness's own session, or nil for a
    /// harness this app doesn't know how to resume. It is typed at the
    /// prompt of a restored shell and run by the user's Enter (see
    /// `restoreInput`), so everything it embeds is one shell word: the
    /// session id — which comes from the harness itself, but is quoted
    /// whenever it carries anything a shell could interpret — and, when
    /// the harness ran under a non-default configuration home, that home
    /// as a leading variable assignment, without which the command would
    /// look for the session in the default location and fail.
    static func resumeCommand(for metadata: SessionResumeMetadata) -> String? {
        let id = shellWord(terminalSafeSingleLine(metadata.sessionID))
        let invocation: String
        let homeVariable: String?
        switch metadata.agent {
        case "omp":
            invocation = "omp --resume \(id)"
            homeVariable = nil
        case "claude":
            invocation = "claude --resume \(id)"
            homeVariable = "CLAUDE_CONFIG_DIR"
        case "codex":
            invocation = "codex resume \(id)"  // no `--`: that's Codex's real syntax
            homeVariable = "CODEX_HOME"
        default:
            return nil
        }
        guard let homeVariable,
              let home = metadata.home.map(terminalSafeSingleLine), !home.isEmpty
        else { return invocation }
        return "\(homeVariable)=\(shellWord(home)) \(invocation)"
    }

    /// Returns a clean title only when the input is recognizably one of the
    /// named agent's own generated decorated forms. This lets a later plain
    /// shell OSC title leave an already-remembered agent title untouched,
    /// and keeps one harness's decoration from ever being mistaken for
    /// another's (e.g. an OMP `π > …` title arriving under agent "claude"
    /// must not be read as a Claude Code title).
    static func normalizedTitle(_ rawTitle: String, agent: String) -> String? {
        let rawTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }
        switch agent {
        case "omp":
            let decorated = parseOmpDecoratedTitle(rawTitle)
            return decorated.recognized ? decorated.title : nil
        case "claude":
            return parseClaudeDecoratedTitle(rawTitle)
        default:
            // Codex and any other unrecognized agent have no known
            // terminal-title decoration.
            return nil
        }
    }

    /// What gets typed into a restored session's fresh shell, in one write:
    /// a `printf` that prints the heading, newline-terminated so the shell
    /// runs it at once, then the resume command with NO newline, so it sits
    /// at the prompt waiting for the user's Enter —
    ///
    ///     Last Claude Code session: Agent session persistence on restart
    ///     ❯ claude --resume 8b5667f6-3fe2-4e76-8c53-a385933a6c4a
    ///
    /// — one keypress to resume, Ctrl-C to decline. The heading names the
    /// harness and the remembered title (a session that never titled
    /// itself falls back to its last prompt; the prompt never gets a line
    /// of its own), and the command is the harness's own resume syntax, so
    /// a glance shows exactly what Enter will do. Nothing runs by itself:
    /// resuming stays the user's decision. A harness with no known resume
    /// syntax gets its session id in the printed text instead, and nothing
    /// typed at the prompt.
    static func restoreInput(for metadata: SessionResumeMetadata) -> String {
        let name = displayName(agent: metadata.agent)
        let heading = (metadata.title ?? metadata.prompt).map(terminalSafeSingleLine)
        var lines = [heading.map { "Last \(name) session: \($0)" } ?? "Last \(name) session"]

        let command = resumeCommand(for: metadata)
        if command == nil {
            lines.append("Session id: \(terminalSafeSingleLine(metadata.sessionID))")
        }

        let arguments = lines.map { "'\(singleQuoted($0))'" }.joined(separator: " ")
        return "printf '%s\\n' \(arguments)\n" + (command ?? "")
    }

    private static func parseOmpDecoratedTitle(_ title: String) -> (recognized: Bool, title: String?) {
        for prefix in ["π >", "π !", "π:"] {
            if title == prefix { return (true, nil) }
            if title.hasPrefix(prefix + " ") {
                return (true, cleanRemainder(title.dropFirst(prefix.count + 1)))
            }
        }

        guard title.hasPrefix("π ") else { return (false, nil) }
        let remainder = title.dropFirst(2)
        guard let spinner = remainder.first, ompSpinnerCharacters.contains(spinner) else {
            return (false, nil)
        }
        let afterSpinner = remainder.dropFirst()
        if afterSpinner.isEmpty { return (true, nil) }
        guard afterSpinner.first == " " else { return (false, nil) }
        return (true, cleanRemainder(afterSpinner.dropFirst()))
    }

    /// Claude Code sets titles as `<glyph> <summary>`. A bare glyph (no
    /// space, nothing after it) or a title with no recognized glyph at all
    /// both return nil — and so does `✳ Claude Code`, the title Claude Code
    /// shows from launch until the first exchange has been summarized: it
    /// names the program, not the conversation, and a banner reading "Last
    /// Claude Code session: Claude Code" would say less than the prompt
    /// fallback it displaced.
    private static func parseClaudeDecoratedTitle(_ title: String) -> String? {
        guard let first = title.first, claudeGlyphs.contains(first) else { return nil }
        let afterGlyph = title.dropFirst()
        guard afterGlyph.first == " " else { return nil }
        let summary = cleanRemainder(afterGlyph.dropFirst())
        return summary == "Claude Code" ? nil : summary
    }

    private static func cleanRemainder(_ remainder: Substring) -> String? {
        String(remainder)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func singleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    /// `value` as one word of a command typed at the prompt: bare when it
    /// consists only of characters no POSIX shell interprets, otherwise
    /// single-quoted with embedded quotes escaped, so a session id or path
    /// carrying metacharacters arrives as an argument and never as a
    /// second command.
    private static func shellWord(_ value: String) -> String {
        let bare = !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".", "/", ":", "@", "%", "+", ",", "=":
                return true
            default:
                return false
            }
        }
        return bare ? value : "'\(singleQuoted(value))'"
    }
}

/// Collapses human-readable whitespace to one space and drops all other
/// control scalars (including ESC/BEL/Ctrl-C), producing one printable line.
private func terminalSafeSingleLine(_ value: String) -> String {
    var result = ""
    var pendingSpace = false
    for scalar in value.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            pendingSpace = !result.isEmpty
        } else if CharacterSet.controlCharacters.contains(scalar) {
            continue
        } else {
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(contentsOf: String(scalar))
        }
    }
    return result
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
