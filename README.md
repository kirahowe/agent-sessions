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

Sessions running Claude Code can show a coloured dot in the sidebar when they
need you:

- **Gold** — the agent finished its turn. Your move, but nothing is stuck.
- **Red** — the agent is blocked on a permission prompt and is doing nothing
  until you answer.

No dot means the agent is working (or the session isn't running an agent).

The app can't detect this on its own, so `hooks/agents-status.sh` reports it
from Claude Code's hooks. It writes an OSC 777 escape to the session's pty,
which the app reads. Requires `jq`.

Wire it up in `~/.claude/settings.json`, using the **absolute** path to your
clone — Claude Code does not expand `~` here:

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
