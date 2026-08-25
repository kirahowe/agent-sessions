import Foundation

/// Persisted information needed to reconnect a restored terminal row to its
/// most recent OMP session. All presentation fields are optional so a valid
/// protocol event can make the session resumable even before OMP publishes a
/// useful terminal title or prompt.
struct OmpSessionResumeMetadata: Codable, Hashable {
    var sessionID: String
    var title: String?
    var prompt: String?
}

/// The small, Foundation-only portion of Warp's CLI-agent notification
/// protocol that the app consumes. Unknown JSON fields and event-specific
/// fields other than `query` are deliberately ignored.
struct OmpSessionEvent: Hashable {
    static let notificationTitle = "warp://cli-agent"

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

    static func parseNotification(title: String, body: String) -> OmpSessionEvent? {
        guard title == notificationTitle,
              let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              envelope.v == 1,
              envelope.agent == "omp"
        else { return nil }

        let name = envelope.event.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = envelope.sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !sessionID.isEmpty else { return nil }

        let query = envelope.query.flatMap { query -> String? in
            let preview = terminalSafeSingleLine(query)
            guard !preview.isEmpty else { return nil }
            return String(preview.prefix(200))
        }
        return OmpSessionEvent(name: name, sessionID: sessionID, query: query)
    }
}

extension OmpSessionResumeMetadata {
    private static let spinnerCharacters: Set<Character> = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    /// Returns a clean title only when the input is recognizably one of OMP's
    /// generated decorated forms. This lets later shell OSC titles leave an
    /// already remembered OMP title untouched.
    static func normalizedDecoratedTitle(_ rawTitle: String) -> String? {
        let rawTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return nil }
        let decorated = parseDecoratedTitle(rawTitle)
        return decorated.recognized ? decorated.title : nil
    }

    static func resumeHintCommand(for metadata: OmpSessionResumeMetadata) -> String {
        let heading = terminalSafeSingleLine(metadata.title ?? metadata.prompt ?? "Previous OMP session")
        var lines = ["OMP session: \(heading)"]
        if let prompt = metadata.prompt {
            let prompt = terminalSafeSingleLine(prompt)
            if prompt != heading {
                lines.append("Prompt: \(prompt)")
            }
        }
        lines.append("Resume: omp --resume \(terminalSafeSingleLine(metadata.sessionID))")
        let arguments = lines.map { "'\(singleQuoted($0))'" }.joined(separator: " ")
        return "printf '%s\\n' \(arguments)\n"
    }

    private static func parseDecoratedTitle(_ title: String) -> (recognized: Bool, title: String?) {
        for prefix in ["π >", "π !", "π:"] {
            if title == prefix { return (true, nil) }
            if title.hasPrefix(prefix + " ") {
                return (true, cleanRemainder(title.dropFirst(prefix.count + 1)))
            }
        }

        guard title.hasPrefix("π ") else { return (false, nil) }
        let remainder = title.dropFirst(2)
        guard let spinner = remainder.first, spinnerCharacters.contains(spinner) else {
            return (false, nil)
        }
        let afterSpinner = remainder.dropFirst()
        if afterSpinner.isEmpty { return (true, nil) }
        guard afterSpinner.first == " " else { return (false, nil) }
        return (true, cleanRemainder(afterSpinner.dropFirst()))
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
