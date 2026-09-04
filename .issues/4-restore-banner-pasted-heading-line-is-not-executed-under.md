# Restore banner: pasted heading line is not executed under bracketed paste

## Context

Raised by the codex review of the libghostty 1.5 upgrade (2026-09-04); it
predates that range and is not a migration regression, since the old
`sendText` and the new `paste(text:)` both call `ghostty_surface_text`,
which Ghostty's `Surface.textCallback` routes to
`completeClipboardPaste(text, true)` — a paste, bracketed whenever the
program at the prompt has enabled mode 2004 (zsh does by default).

`SessionResume.restoreInput` builds `printf '%s\n' '<heading>'\n<resume
command>` and `TerminalCenter` pastes it in one go, documented as "the
heading prints, the resume command is left typed". Under bracketed paste
the embedded newline is pasted text: both lines land in the line editor
as a two-line buffer, the heading is not printed until the user presses
Enter, and Enter then runs both lines. The banner tests inject
`textDelivery`, so they cannot see this.

## Options

- Send the heading as its own paste followed by a real Enter via
  `sendKey(.enter)` (libghostty-spm 1.5 exposes `sendKey`), then paste the
  resume command alone.
- Or drop the printed heading and keep only the pre-typed command, with
  the context shown in the app UI instead.

## Acceptance criteria

- At a zsh prompt with bracketed paste on, the heading is printed and only
  the resume command remains in the buffer, unexecuted.
