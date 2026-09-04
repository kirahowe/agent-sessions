import Foundation

/// When a pane is safe to type into, as a small pure state machine.
///
/// Typing into a pane goes down its pty, and there are two distinct gates
/// before that is safe — hence two distinct meanings this type keeps apart:
///
/// - **the surface exists** (`surfaceAttached`). libghostty builds the pane's
///   surface only once the view is in a window with a real size, an arbitrary
///   number of run-loop turns after the view is mounted, and `paste(text:)`
///   returns false until then. This is the gate for raw type-ahead into a
///   cooked tty: bytes reach the kernel, which will echo them.
/// - **the shell is at its prompt** (`isReady`). A surface alone is not a
///   shell ready for a line of input: while `login` still owns the tty in
///   cooked mode, typed bytes are echoed raw above "Last login" and the
///   prompt then repaints underneath them. The shell reaching its first
///   prompt — known from its first OSC title, or a fallback timer for a shell
///   that never titles itself — is what makes inserting a full command line
///   safe. This is the gate the restore banner waits on.
///
/// Extracted from `TerminalCenter.PaneEntry` so the transitions are unit-
/// tested directly, with no live surface. The one live consumer today is the
/// restore banner, which needs `isReady`; the surface-only gate is kept
/// distinct because it is a real, separately meaningful state, not because a
/// second consumer needs it yet.
struct TerminalReadiness: Equatable {
    /// libghostty has built the surface (there is a pty). Cleared when the
    /// surface is torn down.
    private(set) var surfaceAttached = false

    /// The shell has announced its first prompt (its first OSC title).
    private(set) var promptSeen = false

    /// The prompt fallback fired: a shell that never sets a title is assumed
    /// to be at its prompt `promptFallbackDelay` after the surface attached.
    private(set) var promptFallbackElapsed = false

    /// Bumped on every attach. A fallback timer captures the generation of
    /// the attach that armed it and hands it back to `noteFallbackElapsed`,
    /// so a timer left over from a torn-down surface cannot declare a later
    /// surface's shell ready.
    private(set) var attachGeneration = 0

    /// Ready for a typed line of input: the surface exists AND the shell is
    /// at a prompt (really seen, or assumed after the fallback).
    var isReady: Bool { surfaceAttached && (promptSeen || promptFallbackElapsed) }

    /// Records that libghostty built (or rebuilt) the surface. Returns the
    /// new generation for the caller to capture in the fallback timer it
    /// starts for this surface.
    @discardableResult
    mutating func attach() -> Int {
        surfaceAttached = true
        attachGeneration += 1
        return attachGeneration
    }

    /// The surface was torn down (a quiesce, or the view leaving its window).
    /// Anything typed now would go nowhere, and the next surface's shell
    /// starts from scratch, so both prompt signals reset with it.
    mutating func detach() {
        surfaceAttached = false
        promptSeen = false
        promptFallbackElapsed = false
    }

    /// The shell announced a title. Returns whether this was the FIRST one —
    /// the first title is the first prompt, and the caller may need to act on
    /// that edge (deliver a banner that was waiting on it) exactly once.
    @discardableResult
    mutating func notePrompt() -> Bool {
        let firstPrompt = !promptSeen
        promptSeen = true
        return firstPrompt
    }

    /// The fallback timer armed at `generation` fired. It takes effect (and
    /// returns true) only if the surface is still attached and no later
    /// attach has bumped the generation past it — otherwise the timer belongs
    /// to a surface that no longer exists and is ignored.
    @discardableResult
    mutating func noteFallbackElapsed(generation: Int) -> Bool {
        guard surfaceAttached, attachGeneration == generation else { return false }
        guard !promptFallbackElapsed else { return false }
        promptFallbackElapsed = true
        return true
    }
}
