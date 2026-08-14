# Session attention — design

## Context

Sessions show a sidebar indicator when their agent needs the user: a static gold
dot for "your turn," a pulsing red exclamation for "blocked on a permission
prompt," plus a Dock badge counting blocked sessions.

Today that works only when `hooks/agents-status.sh` is registered in the user's
Claude Code settings. That has three consequences worth fixing:

- **It reaches almost nobody.** The hook lives in the repo and is wired up by
  hand. Anyone installing a released build via Sparkle has no clone, so no
  script to point at. Failure is completely silent — the app looks like it
  simply lacks the feature.
- **It is Claude-Code-only**, in an app whose premise is coordinating agents.
- **We already receive signals we throw away.** `terminalDidRequestDesktopNotification`
  fires for any OSC 9/777 notification on a surface. Gemini CLI emits these
  natively, Claude Code can (`preferredNotifChannel`), and the delegate is
  already implemented — we just `return nil` on anything that isn't our magic
  `agents:status` payload. There is also an unused bell delegate and the full
  OSC 9;4 progress protocol.

The goal: keep the high-fidelity hook path for those who want it, and light up
every agent that emits a standard terminal notification, without the fragility
that comes from bolting sources together.

## Platform facts this design is built on

Verified against the vendored libghostty and its C header — not assumptions:

- **The OSC number is flattened.** `ghostty_action_desktop_notification_s` carries
  only `title`/`body`. OSC 9, 777 and 99 are indistinguishable to us. Text is
  therefore the only semantic signal available.
- **Ghostty rate-limits notifications (~1/sec) and suppresses identical content**
  within a short window. Any design depending on repeated identical messages
  loses some of them. Our current hook emits an identical `clear` on every
  `PreToolUse`/`PostToolUse`, so this is likely already happening.
- **Available and unused:** `TerminalSurfaceBellDelegate` (bare BEL),
  `TerminalSurfaceProgressReportDelegate` (OSC 9;4, states
  `remove/set/error/indeterminate/pause`), `TerminalSurfaceCommandFinishedDelegate`.
- **Not available at all:** OSC 133 prompt-start/command-start, and any "is the
  terminal at a prompt" query. Absent from the C API entirely. Nothing here may
  depend on them.

## Decisions (settled — see cmux prior art below)

1. **Hybrid model behind one central abstraction.** Unread-style attention is
   the floor; structured signals upgrade it to real agent state.
2. **Keyword classification** of notification text detects "blocked."
3. **Strict one-way precedence.** Never mutual suppression.
4. **Silent agents get no indicator.** No idle timers, no process-state guessing.
5. **The hook stays optional**, not required, not auto-installed.
6. **Never hardcode agent config dirs** — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`.

### What cmux taught us

[cmux](https://github.com/manaflow-ai/cmux) is a Ghostty-based macOS terminal
solving nearly this problem. Four lessons shaped the design:

- **Their worst bug class (#2322) was a dual path** — hook and raw OSC — each
  suppressing the other through a possibly-stale cache. It produced *both*
  missed and duplicated notifications. Hence strict one-way precedence here.
- **Their standing architectural debt (#9523)** is agent status written from
  ~20 uncoordinated call sites with no reconciliation layer, so the same race
  bug recurs per integration. Hence: one reducer, one funnel, no other writer.
- **Focus-suppression granularity (#5095, docs)**: auto-withdrawing at a level
  coarser than the unit of attention silently ate notifications for a second,
  unattended agent in the same container. Ours keys on the session, nothing else.
- **`idle_prompt` spam (#3602)**: Claude Code re-fires a reminder ~60s after
  `Stop`. A user called it "a second notification that provides no additional
  value and trains me to ignore notifications altogether." Our indicator is
  idempotent, so this is harmless today — but it must stay that way.

## A. The reconciler

One pure, Foundation-only type. Every signal from every source funnels through
a single reducer; nothing else writes attention state. This is the direct answer
to cmux #9523.

New file `macapp/Agents/SessionAttention.swift` (SwiftUI-free, for the same
reason `SessionActivity.swift` is — trivial unit testing).

```swift
/// Everything that can inform attention state, from any source.
enum AttentionSignal: Equatable {
    case structured(SessionActivity.StatusMessage)  // agents:status payload
    case notification(title: String, body: String)  // free-text OSC 9/777
    case bell                                       // BEL
    case working                                    // agent is demonstrably busy
    case attentionChanged(isAttended: Bool)         // user looking at it
}

/// Resolved per-session state. `activity` is what the sidebar renders.
struct AttentionState: Equatable {
    var activity: SessionActivity?   // nil = show nothing
    var isStructured = false         // sticky: this session has sent a payload
    var isAttended = false           // selected AND app frontmost
}

enum SessionAttention {
    static func reduce(_ state: AttentionState, _ signal: AttentionSignal) -> AttentionState
}
```

`SessionActivity` is unchanged — it stays the render contract, so the existing
indicator, its accessibility treatment and its tests all keep working.

### Precedence

One rule, applied uniformly: **once `isStructured` is true, every non-structured
signal is ignored for that session, permanently.** Not a cache, not a timeout,
not mutual — a sticky one-way latch. A session that has ever spoken the
structured protocol is trusted to keep speaking it.

### Transition table

Exhaustive. `—` means no change.

| Incoming | `isStructured == false` | `isStructured == true` |
|---|---|---|
| `.structured(.set(a))` | `activity = a`, latch `isStructured` | `activity = a` |
| `.structured(.clear)` | `activity = nil`, latch `isStructured` | `activity = nil` |
| `.notification(t, b)` | `activity = classify(t, b)` unless attended | — |
| `.bell` | `activity = activity ?? .yourTurn` unless attended | — |
| `.working` | `activity = nil` | — |
| `.attentionChanged(true)` | `activity = nil`, `isAttended = true` | `isAttended = true` only |
| `.attentionChanged(false)` | `isAttended = false` | `isAttended = false` |

The core stays Foundation-only: libghostty's `TerminalProgressState` is mapped
to a semantic signal at the `SessionDelegateProxy` boundary, not carried into
the reducer. `.set`/`.indeterminate` become `.working`; `.error`/`.pause` become
`.bell`-equivalent raises; `.remove` is dropped as ambiguous (done, or
abandoned — no way to tell).

Three consequences worth stating plainly:

- **`.bell` can only ever raise from nothing.** It never downgrades an existing
  `.blocked` to `.yourTurn`.
- **Raises are dropped while attended.** You are already looking at the session;
  lighting a row you are staring at is pure noise, and it would otherwise stay
  lit forever since no selection change follows.
- **Attending does not clear a structured state.** This is the graceful
  degradation the hybrid model is for. Without a hook, "looked at it" is the
  only honest clear we have. With one, the agent's actual state is known, and
  going dark while it is genuinely still blocked would be a lie — it stays red
  until the hook says otherwise.

### Why this is immune to the Ghostty dedup trap

Nothing in the table depends on receiving a repeated identical message. Clearing
arrives from three independent directions — structured clear, progress, and
attention — so a suppressed duplicate costs nothing.

## B. Wiring

`SessionDelegateProxy` (`TerminalCenter.swift`) additionally implements
`TerminalSurfaceBellDelegate` and `TerminalSurfaceProgressReportDelegate`. The
package dispatches by conditional-casting the single delegate object, so
conformance alone is the registration — same as the notification delegate today.

`SessionTerminating` gains `onSessionSignal: ((String, AttentionSignal) -> Void)?`,
replacing `onSessionActivity`. The proxy no longer parses or decides anything —
it translates a delegate callback into a signal and forwards. All interpretation
moves into the reducer.

`AppStore` replaces `sessionActivity: [String: SessionActivity]` with
`attention: [String: AttentionState]`, and funnels everything through one method:

```swift
func apply(_ signal: AttentionSignal, to sessionID: String) {
    guard sessions.contains(where: { $0.id == sessionID }) else { return }
    attention[sessionID] = SessionAttention.reduce(attention[sessionID] ?? .init(), signal)
}
```

Preserved as-is: never persisted (`PersistedState` untouched), pruned by
`pruneLiveSessionState()`, and `blockedSessionCount` recomputed from
`attention.values` to keep the Dock badge working.

## C. The classifier

Separate pure function, `AttentionClassifier.classify(title:body:) -> SessionActivity`,
matching lowercased cues over `title + " " + body`. Blocked cues are checked
first; anything unmatched falls back to `.yourTurn`.

- **Blocked:** `permission`, `approve`, `approval`, `authorize`, `allow`,
  `permission_prompt`
- **Your turn:** `waiting`, `awaiting`, `idle`, `needs your input`, `finished`,
  `complete`, `done`
- **Fallback:** `.yourTurn` — a notification always means *something* wants you

It is fuzzy, English-only and wording-dependent; that is inherent, since the OSC
number is flattened and text is all we have. The blast radius is contained by
three properties: it can only ever choose between two states, its fallback is
the *safer* one (so a wording change degrades red → gold, never the reverse),
and it is ignored entirely for any session that has sent a structured payload.

## D. Focus and granularity

**The unit of attention is the session** — one pty, one sidebar row. Clearing
keys on session id and nothing coarser. This is exactly where cmux got burned.

`isAttended` is driven from `AppStore.selection` plus app-active state, not
`TerminalSurfaceFocusDelegate`: selection is already the app's own per-session
notion of "what the user is looking at," and the detail area shows exactly one
session, so selection and visibility coincide. Focus delegate callbacks fire on
window-level changes that do not mean the user attended to a *session*.

`.attentionChanged` is emitted on selection change and on app activate/resign.

## E. Testing

No time seam is needed — every signal is event-driven, with no timers, staleness
or debounce anywhere in the design. That is a deliberate outcome; the app has no
clock abstraction today and this design does not force one.

- **Reducer** (`SessionAttentionTests`) — every cell of the transition table,
  following the numbered-case convention in `ToolPreflightTests`. Specifically:
  structured latches and thereafter suppresses classified/bell/progress; bell
  never downgrades blocked; raises dropped while attended; attending clears
  unstructured but not structured state.
- **Classifier** (`AttentionClassifierTests`) — each cue set, cue precedence,
  the unmatched fallback, and case/whitespace tolerance.
- **Wiring** (`AppStoreTests`) — `SpyTerminals` already exposes settable callback
  closures, so tests fire `onSessionSignal` directly. Extend the existing
  activity tests: unknown session ignored, pruning on close, `blockedSessionCount`,
  and the persistence round-trip (`test50`) still asserting nothing survives.

## F. Migration and docs

- `hooks/agents-status.sh` keeps working unchanged — it emits the structured
  payload, which still wins. `sessionEnvVars`/`AGENTS_APP` stay as the gate.
- `SessionActivity.parseStatusMessage` is unchanged and still the structured
  parser; the proxy now hands its result to the reducer rather than to `AppStore`.
- **README correction (required).** The wiring instructions currently hardcode
  `~/.claude/settings.json`. They must resolve **`CLAUDE_CONFIG_DIR`** first and
  treat `~/.claude` only as its default. Add Codex instructions alongside:
  Codex CLI now has lifecycle hooks with nearly the same vocabulary (`Stop`,
  `PermissionRequest`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`), rooted
  at **`CODEX_HOME`** (default `~/.codex`), so the same script serves both.
- **Hook hygiene.** The script should emit only on state *transitions*, not on
  every tool call, since identical repeats are suppressed by Ghostty anyway and
  the noise buys nothing.

## G. Staged delivery

Each stage is independently committable and independently valuable.

1. **Introduce the reducer and classifier; route the existing structured path
   through them.** No behavior change, full test coverage. This is the pure
   refactor to a single funnel, and it lands the anti-#9523 property first.
2. **Classify free-text notifications.** The headline win: every agent already
   emitting OSC 9/777 lights up, with no hook and no setup.
3. **Attention clearing** on selection and app-active.
4. **Bell and progress signals.**
5. **Hook hygiene + README/Codex docs**, including the config-dir correction.

## Verification

- `bb test` for the suite.
- `bb run`, then end to end in a real session: run Claude Code with no hook
  installed and confirm a turn-end notification raises the gold dot and that
  selecting the session clears it; with the hook installed, confirm a permission
  prompt raises the red pulse and that it survives selecting the session until
  approval.
- Test the classifier against real captured notification text from Claude Code
  and Gemini CLI rather than invented strings.
