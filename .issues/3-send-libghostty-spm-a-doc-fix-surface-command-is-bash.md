# Send libghostty-spm a doc fix: surface command is bash source and waitAfterCommand cannot be turned off

## Context

`TerminalSurfaceOptions` (libghostty-spm 1.5) documents `command` as
"overrides the command executed in the child process" and `waitAfterCommand`
as "controls whether the surface stays open after `command` exits instead of
closing immediately". Against the Ghostty the package embeds
(c4e16970a803, `src/apprt/embedded.zig`), both read differently:

- `command` becomes `config.command = .{ .shell = cmd }`: a shell string, on
  macOS run as `login -flp <user> bash --noprofile --norc -c "exec -l <cmd>"`.
  The `direct:` prefix documented for Ghostty's config file is parsed by the
  config loader only; through this API it reaches bash as a program name and
  the command never starts. Paths with spaces need shell quoting.
- Setting a command forces `wait-after-command` on; the `wait_after_command`
  field can only turn it on as well. `waitAfterCommand: false` is a no-op.

Both cost this project a verify-build round to discover (the first
`command:` overlay used `direct:` and `waitAfterCommand: false`, and neither
did anything).

## Plan

Doc-only PR to Lakr233/libghostty-spm on the two properties: state the
shell-string semantics (with the macOS `exec -l` wrapping and a quoting
note) and that `waitAfterCommand` only ever enables waiting. Optionally
change `waitAfterCommand` to a non-optional `Bool` defaulting to false with
the same note, so `false` cannot look meaningful.

## Acceptance criteria

- Upstream doc comments describe the behaviour above; link the PR here.
