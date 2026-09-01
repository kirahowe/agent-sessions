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
}

/// The small, Foundation-only portion of the session-notification protocol
/// this app consumes. Warp's own CLI-agent protocol (which OMP speaks
/// natively) and the app's own hook (`hooks/agents-status.sh`, for Claude
/// Code and Codex) both publish the same JSON envelope shape, just under
/// different notification titles — see `warpNotificationTitle` and
/// `hookNotificationTitle`. Unknown JSON fields and event-specific fields
/// other than `query` are deliberately ignored.
struct AgentSessionEvent: Hashable {
    /// Warp's CLI-agent protocol title — OMP emits this natively.
    static let warpNotificationTitle = "warp://cli-agent"
    /// The app's own title, emitted by hooks/agents-status.sh for Claude
    /// Code and Codex.
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

    static func parseNotification(title: String, body: String) -> AgentSessionEvent? {
        guard isSessionNotification(title: title),
              let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              envelope.v == 1
        else { return nil }

        let agent = envelope.agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = envelope.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = envelope.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty, !name.isEmpty, !sessionID.isEmpty else { return nil }

        let query = envelope.query.flatMap { query -> String? in
            let preview = terminalSafeSingleLine(query)
            guard !preview.isEmpty else { return nil }
            return String(preview.prefix(200))
        }
        return AgentSessionEvent(agent: agent, name: name, sessionID: sessionID, query: query)
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
    /// harness this app doesn't know how to resume.
    static func resumeCommand(for metadata: SessionResumeMetadata) -> String? {
        let id = terminalSafeSingleLine(metadata.sessionID)
        switch metadata.agent {
        case "omp": return "omp --resume \(id)"
        case "claude": return "claude --resume \(id)"
        case "codex": return "codex resume \(id)"  // no `--`: that's Codex's real syntax
        default: return nil
        }
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

    /// The shell command that prints the restore banner into a fresh pane.
    /// Shaped after the message Claude Code itself prints when it quits —
    ///
    ///     Resume this session with:
    ///     claude --resume <id>
    ///
    /// — under one heading naming the harness and the remembered title, so
    /// the text that greets the user after a relaunch is the text they saw
    /// when the agent exited. A session that never titled itself falls
    /// back to its last prompt for the heading; the prompt is never printed
    /// on a line of its own.
    static func resumeHintCommand(for metadata: SessionResumeMetadata) -> String {
        let name = displayName(agent: metadata.agent)
        let headingSource = metadata.title ?? metadata.prompt
        let heading = headingSource.map(terminalSafeSingleLine)

        var lines = [heading.map { "Last \(name) session: \($0)" } ?? "Last \(name) session"]

        if let command = resumeCommand(for: metadata) {
            lines.append("Resume this session with:")
            lines.append(command)
        } else {
            lines.append("Session id: \(terminalSafeSingleLine(metadata.sessionID))")
        }

        let arguments = lines.map { "'\(singleQuoted($0))'" }.joined(separator: " ")
        return "printf '%s\\n' \(arguments)\n"
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
    /// both return nil.
    private static func parseClaudeDecoratedTitle(_ title: String) -> String? {
        guard let first = title.first, claudeGlyphs.contains(first) else { return nil }
        let afterGlyph = title.dropFirst()
        guard afterGlyph.first == " " else { return nil }
        return cleanRemainder(afterGlyph.dropFirst())
    }

    private static func cleanRemainder(_ remainder: Substring) -> String? {
        String(remainder)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func singleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\"'\"'")
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
