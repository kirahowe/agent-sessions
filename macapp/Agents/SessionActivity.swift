import Foundation

/// What a live agent process is doing right now, as far as the session's
/// hooks have told us. Deliberately transient and NEVER persisted: this
/// describes live process state, not app state — a value restored from disk
/// on next launch would always be a lie (the process it described no longer
/// exists, or is doing something else by then).
enum SessionActivity: String, Hashable {
    case yourTurn = "your-turn"
    case blocked  = "blocked"
}

extension SessionActivity {
    /// The magic OSC notification title Claude Code hooks use, so genuine
    /// desktop notifications from other programs are never mistaken for a
    /// status update.
    static let statusTitle = "agents:status"

    enum StatusMessage: Hashable {
        case set(SessionActivity)
        case clear
    }

    /// Parses an OSC 9 / OSC 777 desktop-notification title+body pair into a
    /// status update, or nil if the message isn't one of ours.
    ///
    /// Two wire forms are supported because which field a one-field OSC 9
    /// message lands in is a libghostty detail we should not depend on:
    ///   - OSC 777 (has a real title field): title == "agents:status", body
    ///     is the token — `ESC ] 777 ; notify ; agents:status ; <token> BEL`.
    ///   - OSC 9 (single field): the whole "agents:status:<token>" string may
    ///     be routed to either the title or the body, so both are accepted.
    static func parseStatusMessage(title: String, body: String) -> StatusMessage? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let oscPrefix = "agents:status:"

        let token: String
        if trimmedTitle == statusTitle {
            token = trimmedBody
        } else if trimmedTitle.hasPrefix(oscPrefix) {
            token = String(trimmedTitle.dropFirst(oscPrefix.count))
        } else if trimmedBody.hasPrefix(oscPrefix) {
            token = String(trimmedBody.dropFirst(oscPrefix.count))
        } else {
            return nil
        }

        if token == "clear" {
            return .clear
        }
        if let activity = SessionActivity(rawValue: token) {
            return .set(activity)
        }
        // An unrecognised token must not be silently treated as any
        // particular state (e.g. defaulted to .clear or some fallback) —
        // that would risk showing a stale or flat-out wrong indicator
        // indefinitely if the hook script and this app ever drift out of
        // sync on the wire format. Returning nil here means "not a status
        // update we understand," exactly like an unrelated notification.
        return nil
    }
}
