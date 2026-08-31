# Session-scoped reviews and native split panes

## Decision

Agents keeps its native terminal substrate — libghostty surfaces owned by
`TerminalCenter` — and grows two features on it:

1. A RevDiff review is scoped to the session that invoked it. It fills the
   detail pane only while that session is selected; selecting another session
   shows that session's normal terminal.
2. Split panes within a session, built on the existing surface architecture.

A tmux substrate was evaluated and rejected. It solves review scoping only by
interposing itself on every terminal interaction, permanently: native
scrollback and selection are replaced by copy-mode, the user's prefix key and
tmux configuration leak into sessions that should look like plain terminals,
and the agent protocols this app depends on (structured attention, resume
metadata, OSC notifications, progress reports) survive only where passthrough
framing can be arranged — which is not under our control for tools that do not
know they are inside tmux. The multiplexer features tmux would bring are
already answered natively: the sidebar is the window model, Ghostty provides
scrollback, and resume metadata covers persistence. What the native path keeps
is the private control protocol and the user-level launcher patch — small,
stable, and contained.

## Session-scoped reviews

Today `TerminalHostView` gives the single overlay priority over every
selection, which is why a review can take over unrelated work. The fix is
routing, not new machinery.

- `TerminalCenter.sessionEnvVars` becomes a function of the session id and
  additionally stamps `AGENTS_SESSION_ID` into every session surface. The
  existing variables and the reasons for them are unchanged.
- The launcher forwards `AGENTS_SESSION_ID` in its control-socket request. The
  request protocol gains a required session field; a request with a missing or
  unknown session id is refused and the launcher reports the error. There is
  no app-global fallback — a review either belongs to a live session or does
  not open.
- `OverlayCenter`'s single slot becomes a map keyed by invoking session id:
  at most one review per session, any number of sessions reviewing
  concurrently. A second request from the same session is refused, as today.
- `TerminalHostView` shows an overlay only when the selected session owns one;
  otherwise it shows the selected session's terminal. A review whose session
  is not selected stays mounted but hidden — its process keeps running, the
  invoking agent stays blocked on the launcher, and reselecting the session
  restores the review exactly where it was.
- A hidden open review raises the session's blocked attention state, so the
  sidebar shows that a review is waiting rather than letting it sit
  invisibly.
- Review exit dismisses the overlay and unblocks the launcher regardless of
  visibility. Closing or quiescing a session with a live review dismisses the
  review first and unblocks its launcher with a failure, then proceeds with
  the session teardown.

The user-level launcher patch is updated for the new request field in the same
delivery. Teaching the upstream launcher a proper `agents` backend is a
possible later cleanup, not part of this work.

## Native split panes

The hard parts of a multiplexer — virtual terminals, buffer reparsing,
detach — are not needed: libghostty provides real surfaces. What remains is a
layout and focus problem.

### Layout model

Each session owns a small binary tree: a leaf is a pane with a stable UUID; an
interior node has an orientation and a split ratio. It is a value type with
pure operations (split, close, collapse, resize) and is unit-tested on its
own, independent of AppKit.

### Surface ownership

`TerminalCenter` re-keys its entries by pane id, grouped by session.
`SessionDelegateProxy` closes over a pane id; attention signals from any pane
aggregate up to the session row, and the focused pane's title drives the row
title. New panes spawn the user's login shell in the session's working
directory with the same stamped environment, including the shared
`AGENTS_SESSION_ID`.

### View layer

All pane surfaces remain direct children of the one container view, mounted
once and never reparented — reparenting blanks a live Metal surface, the
constraint `TerminalHostView` is already built around. The layout tree drives
constraints; thin divider views provide drag-to-resize. `NSSplitView` is not
used: inserting one on first split would force reparenting the existing
surface.

### Focus and interaction

One focused pane per session, with a minimal visual indication. Click to
focus. Keyboard commands: split right, split down, close pane, move focus
directionally. Selection, clipboard, scrollback, and drag and drop are per
pane and remain fully native.

### Lifecycle

- A pane's process exit collapses its tree node. The last pane's exit removes
  the session row through the existing `terminalDidClose` path.
- Close and quiesce tear down all of a session's panes.
- The resume hint prints once, in the session's initial pane only.
- Split layout is not persisted across relaunch: the processes do not survive
  anyway, so a restored session starts with a single pane and the existing
  resume behavior.
- A review covers the session's entire pane area, whatever the split layout.
  Reviews are per session, not per pane.

## Testing

Automated coverage:

- per-session environment stamping, including `AGENTS_SESSION_ID`;
- control requests: session-id validation, refusal of missing/unknown ids,
  launcher unblock ordering on exit, close, and quiesce;
- overlay map: one review per session, concurrent sessions, dismissal during
  session teardown;
- no code path grants a review priority over an unrelated session's
  selection;
- layout tree operations: split, close, collapse, ratio adjustment;
- pane exit collapses the right node; last-pane exit removes the correct row;
- attention aggregation and title routing across panes;
- resume hint prints once and only in the initial pane.

Manual matrix:

1. Two sessions, an agent and a review in each. Each review stays with its
   own sidebar row; switching hides and restores it; the other session stays
   interactive throughout.
2. Annotate and quit one review. Only its invoking agent resumes; the other
   review remains open.
3. With a review open in an unselected session, verify the blocked indicator;
   close that session and confirm the launcher unblocks with an error and
   nothing is orphaned.
4. Create, resize, and close splits; run agents in separate panes; verify
   attention dots, titles, and focus movement.
5. Exercise scrollback, selection, clipboard, mouse, and drag and drop per
   pane.
6. Relaunch: restored sessions come back as a single pane with one resume
   hint.

Run `bb test` and the macOS test suite after the focused tests.

## Delivery sequence

1. Session-scoped reviews: per-session env, the request's session field,
   the overlay map, host-view routing, blocked-attention signal, launcher
   patch update, and tests.
2. Layout model plus `TerminalCenter` re-keying, with a single pane as the
   degenerate tree — no visible UI change yet.
3. Split UI: commands and shortcuts, constraint layout, dividers, focus.
4. Full verification and the manual matrix.

## Non-goals

- tmux or any multiplexer as a terminal substrate;
- detach/reattach or process persistence beyond resume metadata;
- pane zoom, broadcast input, or pane swapping in v1;
- persisting split layout across relaunch;
- per-pane reviews;
- windows or tabs beyond the sidebar.
