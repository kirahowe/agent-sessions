# Agents

A minimal native macOS app: a sidebar organizes terminal sessions under
project directories, with real [Ghostty](https://ghostty.org)-rendered
terminals (running your actual login shell) in the detail area.

## Prerequisites

- Xcode (macOS 15+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Babashka](https://babashka.org/): `brew install borkdude/brew/babashka`

## Usage

```sh
bb run
```

This generates the Xcode project, builds it, and launches the app. Individual
steps are also available: `bb gen`, `bb build`, `bb clean`.

The generated `macapp/Agents.xcodeproj` and build output under `macapp/.build`
are gitignored — `bb gen` regenerates the project from `macapp/project.yml`
whenever you need it.

## Resuming OMP sessions after a restart

The app remembers the last OMP session associated with each terminal. After
relaunching Agents, opening a restored terminal starts a fresh shell and prints
the remembered session title, an optional prompt preview, and an explicit
resume command:

```text
OMP session: Add optional OMP session resume
Prompt: Persist the last session for each terminal
Resume: omp --resume 01a03bbc-0713-729c-a74b-b66f49ddeddd
```

Agents never runs that command automatically. Resuming can rebuild provider
caches and spend tokens, so the decision stays with you.

This integration currently supports OMP's default profile. It needs no hook or
OMP configuration: terminals spawned by Agents opt into OMP's built-in
CLI-agent protocol, then persist the session metadata OMP reports. Named OMP
profiles are not included in that protocol yet, so Agents cannot construct a
profile-qualified resume command for them.

## Waiting indicators

Sessions show an indicator in the sidebar when their agent needs you:

- **Gold dot** — the agent finished its turn. Your move, but nothing is stuck.
- **Red pulsing exclamation mark** — the agent is blocked on a permission
  prompt and is doing nothing until you answer. Blocked sessions are also
  counted on the Dock tile's badge, so they stay visible when the app isn't
  focused.

No indicator means the agent is working, or has nothing to say.

The two states differ by shape and motion, not only by colour: a session that
can wait indefinitely and one that is burning time deserve different urgency,
and a hue-only difference is no difference at all to anyone with colour-vision
deficiency. The pulse honours the system Reduce Motion setting — with it on,
the blocked glyph renders statically.

### With no setup at all

Any agent that emits an ordinary terminal desktop notification lights up a
session. Gemini CLI does this natively, and Claude Code can be asked to
(`preferredNotifChannel`). The app also listens for the terminal bell and for
OSC 9;4 progress reports.

Notification text is classified by keyword — wording about permission or
approval raises the red pulse, everything else raises the gold dot. That is
fuzzy by nature: the terminal protocol flattens the notification down to a
title and body, so the text is the only signal there is. It errs toward gold,
so unfamiliar wording costs you a less urgent indicator rather than a missed
permission prompt.

Selecting a session clears an indicator raised this way. Without a hook,
"you looked at it" is the only honest evidence that you've seen it.

### With the hook, for real agent state

`hooks/agents-status.sh` reports the agent's actual state instead of guessing
at it, by writing an OSC 777 escape to the session's pty. It's optional, and
it needs `jq`.

What it buys is trust. A session that speaks this protocol is believed over
keyword classification for the rest of its life, so its red pulse **survives
you selecting the session** and clears only when the agent says it's
unblocked — rather than going dark the moment you glance at a session that is
still, in fact, stuck.

The script only emits when `AGENTS_APP` is set in its environment, which this
app stamps into every terminal it spawns. That makes it safe to register
globally, as below: in iTerm2, Terminal.app, or any other host, the hook sees
no `AGENTS_APP` and exits without writing anything — which matters, because a
terminal that renders OSC 777 as a real desktop notification would otherwise
pop one for real.

It also emits only when the state actually changes, so a long agent turn
writes nothing down the pty after the first escape.

#### Claude Code

Wire it up in `settings.json` under Claude Code's config directory. That is
**`$CLAUDE_CONFIG_DIR`** if you have it set, and `~/.claude` only as the
default — if you've relocated your config, `~/.claude` may not exist at all:

```sh
"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
```

Use the **absolute** path to your clone; Claude Code does not expand `~`
here. If you already run another status script (an iTerm2 tab-colour hook,
say), add this one alongside it as a second entry in the same `hooks` array
rather than replacing it:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ]
  }
}
```

`Stop` and `Notification` raise the indicator; the rest clear it.
`PreToolUse`/`PostToolUse` are what clear the red after you approve a
permission prompt — approving isn't a `UserPromptSubmit`, so nothing else
would. `SessionStart` is not strictly required; it just resyncs a fresh
session so the first real event is guaranteed to be sent.

#### Codex

Codex CLI's lifecycle hooks share the event vocabulary and the JSON-on-stdin
payload, so the same script serves both. Its config lives at
`$CODEX_HOME/hooks.json` — again an env var first, with `~/.codex` as the
default — and takes the same shape:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "/path/to/agents/hooks/agents-status.sh" }] }
    ]
  }
}
```

Two differences from Claude Code. Codex has no `Notification` event —
`PermissionRequest` is a first-class event and is what raises the red pulse.
And Codex requires you to explicitly trust a hook before it will run one; run
`/hooks` inside Codex to review and approve it.

The script exits 0 and stays silent on anything it doesn't recognise, so it
is harmless in terminals other than this app, and under agents that send it
events it has no opinion about.
