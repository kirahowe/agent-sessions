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

## Waiting indicators

Sessions running Claude Code can show an indicator in the sidebar when they
need you:

- **Gold dot** — the agent finished its turn. Your move, but nothing is stuck.
- **Red pulsing exclamation mark** — the agent is blocked on a permission
  prompt and is doing nothing until you answer. Blocked sessions are also
  counted on the Dock tile's badge, so they stay visible when the app isn't
  focused.

No indicator means the agent is working (or the session isn't running an
agent).

The two states differ by shape and motion, not only by colour: a session that
can wait indefinitely and one that is burning time deserve different urgency,
and a hue-only difference is no difference at all to anyone with colour-vision
deficiency. The pulse honours the system Reduce Motion setting — with it on,
the blocked glyph renders statically.

The app can't detect any of this on its own, so `hooks/agents-status.sh`
reports it from Claude Code's hooks. It writes an OSC 777 escape to the
session's pty, which the app reads. Requires `jq`.

The script only emits when `AGENTS_APP` is set in its environment, which this
app stamps into every terminal it spawns. That makes it safe to register
globally, as below: in iTerm2, Terminal.app, or any other host, the hook sees
no `AGENTS_APP` and exits without writing anything — which matters, because a
terminal that renders OSC 777 as a real desktop notification would otherwise
pop one on every single tool call.

Wire it up in `~/.claude/settings.json`, using the **absolute** path to your
clone — Claude Code does not expand `~` here. If you already run another
status script (an iTerm2 tab-colour hook, say), add this one alongside it as a
second entry in the same `hooks` array rather than replacing it:

```json
{
  "hooks": {
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

All five events matter: `Stop` and `Notification` raise the indicator,
and the other three clear it. `PreToolUse`/`PostToolUse` are what clear the
red after you approve a permission prompt — approving isn't a
`UserPromptSubmit`, so nothing else would.

The script exits 0 and stays silent on anything it doesn't recognise, so it
is harmless in terminals other than this app.
