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

## Releases

There is one release channel: a rolling `nightly` prerelease on GitHub,
which the Nightly workflow (`.github/workflows/nightly.yml`) rebuilds from
`main` every morning at 09:00 UTC, skipping the run when nothing has
changed. The same workflow regenerates the signed Sparkle appcast attached
to that release, and that appcast is what **Agents ▸ Check for Updates…**
reads — so publishing a release and making it available to the updater are
one act.

To publish `main` now rather than waiting for the schedule:

```sh
bb publish
```

This dispatches the workflow for `main`, watches the run to completion, and
prints the resulting release. It refuses if the local `main` bookmark is not
what GitHub has, so an unpushed fix cannot be silently left out, and it does
nothing (successfully) when the current nightly is already built from
`main`. It needs the `gh` CLI, logged in with write access to the
repository. The build happens on GitHub rather than on the machine running
the task on purpose: the runner pins the SDK the app is compiled against,
and the appcast is signed with a key that exists only in the repository's
secrets.

## Workspaces

A workspace is an isolated draft of a project: agents read, write, and run
commands in it without touching the project's own files. Create one with
**New Workspace** (⌘N) from the File menu, or from a project's header menu —
either way you pick the project and can set an optional sidebar label. It
lives on disk at `~/.agents/workspaces/<project>-<hash>/<generated-name>`,
outside every repository — keyed by project so two projects' generated
names never collide, with a short hash of the project's path so two
checkouts with the same name don't share a directory (the label is
sidebar-only; it never renames the workspace). It's a jj workspace or a
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
a session that was running an agent gets its resume banner (see "Resuming
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

## Archiving projects

A project you are not working in right now can be archived out of the
sidebar. Swipe its row leftward (two fingers on a trackpad) and choose
**Archive**, or swipe all the way; the same action is on the row's ellipsis
and context menus, and on the File menu as **Archive Project** for the
selected session's project.

Archiving stops the project's terminals, exactly as removing it does, but
keeps everything else the app knew: the sessions with their names, agent
titles and resume hints, and the workspace rows. Nothing on disk changes —
not the project, not its workspaces, not its repository — so there is
nothing to confirm.

Archived projects gather in a collapsed **Archived** section at the bottom of
the sidebar, most recently archived first, each with its path under its name.
Click one (or swipe it rightward and choose **Restore**) to put it back at
the end of the project list with its sessions as they were; opening a
restored session prints its resume hint, as after a relaunch. Adding a
project whose directory is archived restores it the same way rather than
opening a second copy. **Remove Project…**, on an archived row's menu, is
what forgets it for good.

## Resuming agent sessions after a restart

The app remembers the last agent session associated with each terminal,
whichever harness it was running. After relaunching Agents, opening a
restored terminal starts a fresh shell, prints one line naming the harness
and the remembered session title (or, for a session that never titled
itself, your last prompt), and leaves the harness's own resume command typed
at the prompt, waiting:

```text
Last Claude Code session: Make the resume hint harness agnostic
❯ claude --resume 01a03bbc-0713-729c-a74b-b66f49ddeddd
```

Press Enter to resume it, or Ctrl-C to clear the line and use the shell for
something else. Agents never presses Enter for you: resuming starts the
harness, the first prompt you send it spends tokens, and restoring twenty
terminals should not start twenty agents unasked. The banner is typed once
the shell reaches its first prompt — known from the first terminal title it
sets — or, for a shell that never sets one, a few seconds after the terminal
opens.

How the app learns the session id depends on the harness:

| Harness     | Session announced by                            | Resume command         |
|-------------|-------------------------------------------------|------------------------|
| Claude Code | `hooks/agents-status.sh` (see below)            | `claude --resume <id>` |
| Codex CLI   | `hooks/agents-status.sh` (see below)            | `codex resume <id>`    |
| OMP         | OMP's built-in Warp CLI-agent protocol, no setup | `omp --resume <id>`    |

If the harness was running under a non-default configuration home —
`CODEX_HOME` for Codex, `CLAUDE_CONFIG_DIR` for Claude Code — the typed
command carries it as a prefix, `CODEX_HOME=/path codex resume <id>`. That
directory is where the harness keeps the session; a fresh shell that doesn't
export the variable would otherwise look in the default location and find
nothing.

Claude Code and Codex announce their session through the same hook that
reports status (see "With the hook, for real agent state"). The hook
announces the session on every registered event, so even a partial
registration works — but the prompt preview comes only from
`UserPromptSubmit`, and a session that never calls a tool is only announced by
`SessionStart`, so register both if you want the banner to be reliable.

A harness running inside another harness's terminal — `codex exec` launched
from a Claude Code session to review its work, say — is not announced. The
terminal belongs to the outer agent, and the inner one's short-lived session
is not what you want back after a relaunch.

OMP needs no hook: terminals spawned by Agents opt into OMP's built-in
CLI-agent protocol, and the app persists what OMP reports. Only OMP's default
profile is covered — named profiles are not part of that protocol yet, so the
app cannot construct a profile-qualified resume command for them.

### When no banner appears

The hook and the app are versioned together: the hook talks to the app over
its control socket in a form the app has to understand, so after pulling
this repository the installed app must be at least as new as the hook
(**Agents ▸ Check for Updates…**). The hook writes one line to
`~/Library/Logs/Agents/hook.log` whenever something is wrong — a pane spawned
by an older app, a refusal, no answer — and nothing when all is well. So an
empty log beside a missing banner means the hook never ran (check the
`hooks` entries in your harness settings), while a log full of
`no AGENTS_PANE_ID` means the app is older than the hook. The app itself logs
`Agents: session … is now resumable as …` when it records a session and
`typed restore banner` when it prints one; both are visible in Console.app
or with `log show --predicate 'process == "Agents"' --last 1h`. Setting
`AGENTS_HOOK_DEBUG=1` in the harness's environment logs every hook decision,
including the sessions it declined to announce.

## Agent dashboard

The right-side Agent Dashboard is a triage queue of only the sessions that
need you: a "Blocked on you" section first, then "Waiting for you", each headed
by its indicator and a count. Every card shows the session, its project and
workspace, and how long it has been in that state — "now" for the first
minute, then whole minutes, hours, or days, timed from the moment the state was
raised or escalated, so a repeated signal never restarts it. Sessions with no
attention signal are hidden rather than listed at the bottom; the footer still
counts every open session, so the difference is how many are quiet. When
sessions are open but none need attention, the pane says so. Selecting a card
opens that terminal. Use the trailing-sidebar toolbar button to collapse or
reopen the pane.

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
at it, by sending one line per hook event to the app's control socket. It's
optional, and it needs `jq` (and `nc`, which macOS ships).

What it buys is trust. A session that speaks this protocol is believed over
keyword classification for the rest of its life, so its red pulse **survives
you selecting the session** and clears only when the agent says it's
unblocked — rather than going dark the moment you glance at a session that is
still, in fact, stuck.

The script only speaks when it finds the app's environment — `AGENTS_APP`,
`AGENTS_CONTROL_SOCK`, `AGENTS_SESSION_ID`, and `AGENTS_PANE_ID`, which this
app stamps into every pane it spawns. That makes it safe to register
globally, as below: in iTerm2, Terminal.app, or any other host, the hook
finds none of them and exits without doing anything.

It talks to the app directly rather than through the terminal, for a reason
worth knowing if you ever write your own: Ghostty throttles desktop
notifications app-wide — one per second, with identical content suppressed
for five — so a hook that writes OSC escapes to the pty loses any report
landing within a second of another one, and cannot tell, because the write
succeeded. The app still understands the `agents:status` and `agents:session`
OSC forms from other emitters; the bundled hook no longer uses them.

The same line also announces the agent's session id — and, on each prompt, a
short preview of what you asked, and the configuration home the harness runs
under — so the app can print the restore banner described in "Resuming agent
sessions after a restart". It tells Claude Code and Codex apart by looking at
the process that invoked it, so nothing needs configuring per harness.

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
would. `SessionStart` and `UserPromptSubmit` are what make the resume hint
reliable: only `UserPromptSubmit` carries the prompt preview, and only
`SessionStart` catches a session that never calls a tool.

If you script this rather than editing by hand — an agent wiring itself up,
say — merge into the existing file and write the result **in place**.
`settings.json` is often a symlink into a dotfiles repo, and
`jq … > tmp && mv tmp settings.json` silently swaps the link for a plain
copy that the repo never sees again. This merges the hook into all six
events, is safe to re-run, and writes through the link:

```sh
f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
cmd=/path/to/agents/hooks/agents-status.sh
[ -f "$f" ] || echo '{}' > "$f"
jq --arg cmd "$cmd" '
  def ensure($ev; $new):
    .hooks[$ev] |= (
      . // [] |
      if any(.[]; (.hooks // []) | any((.command // "") | contains($cmd))) then .
      elif length > 0 then .[0].hooks += [{type: "command", command: $cmd}]
      else [$new + {hooks: [{type: "command", command: $cmd}]}]
      end);
  ensure("SessionStart"; {}) | ensure("Stop"; {}) | ensure("Notification"; {})
  | ensure("UserPromptSubmit"; {}) | ensure("PreToolUse"; {matcher: "*"})
  | ensure("PostToolUse"; {matcher: "*"})
' "$f" > "$f.new" && cat "$f.new" > "$f" && rm "$f.new"
```

Where an event already has a hook group the command joins that group and
inherits its matcher; events with no group get the shapes shown above.

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
`/hooks` inside Codex to review and approve it. If you script the edit, write
`hooks.json` in place, for the same reason as above.

If you run Codex through a wrapper that sets `CODEX_HOME` — a shell function
such as `cdk () { CODEX_HOME=~/.codex-kira codex "$@"; }` — the hook file
belongs under that home, and the restore banner's command will carry the
same `CODEX_HOME=…` prefix, since that is where those sessions live.

The script exits 0 and stays silent on anything it doesn't recognise, so it
is harmless in terminals other than this app, and under agents that send it
events it has no opinion about.
