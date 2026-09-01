# Agents

A minimal native macOS app: a sidebar organizes terminal sessions under
project directories, with real [Ghostty](https://ghostty.org)-rendered
terminals (running your actual login shell) in the detail area.

## Prerequisites

- Xcode (macOS 15+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Babashka](https://babashka.org/): `brew install borkdude/brew/babashka`
- Temporary local checkout of
  [workstream-manager](https://github.com/kirahowe/workstream-manager) at
  `$HOME/code/projects/workstream-manager` (until the dependency is
  published). Set `WORKSTREAM_MANAGER_ROOT` to use a different checkout.

## Usage

```sh
bb run
```

This generates the Xcode project, builds it, and launches the app. Individual
steps are also available: `bb gen`, `bb build`, `bb clean`.

The generated `macapp/Agents.xcodeproj` and build output under `macapp/.build`
are gitignored — `bb gen` regenerates the project from `macapp/project.yml`
whenever you need it.

## Workspaces

A workspace is an isolated draft of a project: agents read, write, and run
commands in it without touching the project's own files. Create one with
**New Workspace** (⌘N) from the File menu, or from a project's header menu —
either way you pick the project and can set an optional sidebar label. It
lives on disk at `<project>/workspaces/<generated-name>` (the label is
sidebar-only; it never renames the workspace), and it's a jj workspace or a
git worktree depending on the project, detected automatically — a colocated
jj/git repo is treated as jj. Each workspace keeps its own sessions in the
sidebar, nested underneath it.

### Closing a workspace

**Close Workspace…**, on a workspace row's context menu (or its ellipsis
button), or on the File menu for the selected session's workspace, opens one
sheet that covers every outcome:

- With changes to add, the sheet lists them in plain language and offers
  **Add Changes & Close** — add the draft to the project's shared progress,
  then remove the workspace — or the destructive **Close Without Adding…**,
  which asks once more before it proceeds.
- If some of those changes are undescribed, the sheet asks for a one-line
  summary before it will add them.
- With nothing to add, it just offers **Close Workspace** and **Cancel**.
- If the changes overlap newer project progress, the sheet says so and offers
  **Return to Workspace** or **Close Without Adding…** — it never offers an add
  it can predict would conflict. If a conflict only turns up once the add is
  under way, the changes are moved onto the latest project progress with the
  conflicts marked and the workspace stays open: resolve them there and close
  it again, or back out with `jj undo` (`git rebase --abort`).
- If the project has no shared progress yet — a brand-new repo — the sheet
  offers to set the project up with these changes as its starting point.

Closing stops every session in that workspace before anything changes, because
the workspace's files are about to be rewritten out from under them. The sheet
tells you how many sessions it will stop. If the close is refused — an overlap,
or the workspace changing mid-flight — the sessions come back as fresh shells;
a session that was running an agent prints its resume command (see "Resuming
agent sessions after a restart" below).

After a successful add, the app also brings the project root's own unlanded
work up to date with the new progress, automatically — but only when no
sessions are open there, since updating it any other time would rewrite files
out from under a running agent. When it can't reconcile automatically, the
project header shows an orange triangle and its menu offers **Refresh Project
Workspace** instead. Nothing is lost either way, and other open workspaces are
never rewritten by someone else's close — each one reconciles with the latest
progress on its own, the next time it closes.

For the curious: adding changes means, under jj, rebasing the workspace's
commits onto trunk and moving the trunk bookmark; under git, rebasing the
`agents/<name>` branch, fast-forwarding trunk, and deleting the now-merged
branch. Either way the workspace is deregistered afterwards. Nothing is
copied aside first: the version control system's own record — jj's operation
log, git's reflog — is the safety net if an add ever needs unwinding by
hand. Closing without adding just deregisters the
workspace and moves its folder to the Bin — the commits stay in the
repository's history (jj) or on the `agents/<name>` branch (git), so they're
recoverable by hand.

## Resuming agent sessions after a restart

The app remembers the last agent session associated with each terminal,
whichever harness it was running. After relaunching Agents, opening a
restored terminal starts a fresh shell and prints the remembered session
title (or, for a session that never titled itself, your last prompt) followed
by the same resume text the harness printed when it quit:

```text
Last Claude Code session: Make the resume hint harness agnostic
Resume this session with:
claude --resume 01a03bbc-0713-729c-a74b-b66f49ddeddd
```

Agents never runs that command automatically. Resuming can rebuild provider
caches and spend tokens, so the decision stays with you.

How the app learns the session id depends on the harness:

| Harness     | Session announced by                            | Resume command         |
|-------------|-------------------------------------------------|------------------------|
| Claude Code | `hooks/agents-status.sh` (see below)            | `claude --resume <id>` |
| Codex CLI   | `hooks/agents-status.sh` (see below)            | `codex resume <id>`    |
| OMP         | OMP's built-in Warp CLI-agent protocol, no setup | `omp --resume <id>`    |

Claude Code and Codex announce their session through the same hook that
reports status (see "With the hook, for real agent state"). The hook
announces the session from whichever registered event fires first, so even a
partial registration works — but the prompt preview comes only from
`UserPromptSubmit`, and a session that never calls a tool is only announced by
`SessionStart`, so register both if you want the hint to be reliable.

OMP needs no hook: terminals spawned by Agents opt into OMP's built-in
CLI-agent protocol, and the app persists what OMP reports. Only OMP's default
profile is covered — named profiles are not part of that protocol yet, so the
app cannot construct a profile-qualified resume command for them.

## Agent dashboard

The right-side Agent Dashboard shows only the sessions that need you: blocked
sessions first, then sessions waiting for you. Sessions with no attention
signal are hidden rather than listed at the bottom. The summary line above the
list still counts every open session, so the difference is how many are
hidden. When sessions are open but none need attention, the pane says so.
Selecting a row opens that terminal. Use the trailing-sidebar toolbar button to
collapse or reopen the pane.

The all-quiet state says the hidden sessions are “working or idle” rather than
“working” on purpose: without a structured status signal, the app cannot
distinguish a running agent from an idle shell.

## Waiting indicators

Sessions show an indicator in the sidebar when their agent needs you:

- **Gold dot** — the agent finished its turn. Your move, but nothing is stuck.
- **Red pulsing exclamation mark** — the agent is blocked on a permission
  prompt and is doing nothing until you answer. Blocked sessions are also
  counted on the Dock tile's badge, so they stay visible when the app isn't
  focused.

No indicator means the app has no attention signal; the agent may be working
or idle.

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

The same script also announces the agent's session id — and, on each prompt,
a short preview of what you asked — so the app can print the resume hint
described in "Resuming agent sessions after a restart". It tells Claude Code
and Codex apart by looking at the process that invoked it, so nothing needs
configuring per harness.

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
would. `SessionStart` resyncs a fresh session so the first real event is
guaranteed to be sent, and together with `UserPromptSubmit` it is what makes
the resume hint reliable: the session is announced from whichever event fires
first, but only `UserPromptSubmit` carries the prompt preview, and only
`SessionStart` catches a session that never calls a tool.

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
