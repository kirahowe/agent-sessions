# Upstream a child-exited delegate to libghostty-spm and drop the overlay wrapper

## Context

Found while moving the review overlay onto `TerminalSurfaceOptions.command`
(libghostty-spm 1.5.20260903, Ghostty upstream c4e16970a803). Two runtime
facts, both verified against the pinned Ghostty source
(`src/apprt/embedded.zig`, `Surface.init`) and reproduced in a verify build:

- The embedded runtime forces `wait-after-command = true` whenever a surface
  is spawned with a `command`, and `ghostty_surface_config_s.wait_after_command`
  can only set it to true. So a surface whose command exits stays open at
  Ghostty's "Process exited. Press any key" line, and `close_surface_cb`
  (`terminalDidClose`) fires only after a keypress.
- Ghostty reports the exit to the apprt as `GHOSTTY_ACTION_SHOW_CHILD_EXITED`
  (with exit code and runtime), but libghostty-spm's `TerminalCallbackBridge`
  does not route that action to any delegate, and the raw `ghostty_surface_t`
  (`ghostty_surface_process_exited`) is private to `TerminalSurface`.

The app therefore runs each review through the bundled `overlay-run.sh`
with a token minted per review; once the review has ended the wrapper sets
the terminal title to that token and the app dismisses the overlay when it
arrives as `terminalDidChangeTitle` — unambiguous (no child can guess the
token) but still a cooperative wrapper protocol, not a process-exit event
(see `OverlayCenter.swift`).

## Plan

1. PR to Lakr233/libghostty-spm: handle `GHOSTTY_ACTION_SHOW_CHILD_EXITED` in
   the bridge and add a `TerminalSurfaceChildExitedDelegate` (exit code,
   runtime). Returning `true` from the action callback would also suppress
   the in-terminal "Process exited" text, which an embedding host may want
   to draw itself.
2. Once a release carries it: `OverlayDelegateProxy` adopts the new delegate,
   `present` passes the launcher's script as the command directly (still
   quoted), and `Resources/overlay-run.sh` plus its tests go away.

## Acceptance criteria

- A review overlay dismisses on the command's exit with no wrapper in the
  process tree and no title token written by the app.
- `terminalDidClose` remains the fallback and stays idempotent with the new
  callback.
